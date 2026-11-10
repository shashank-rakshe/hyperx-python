"""
Your own models -> PRIVATE training samples (never commit the output).

1. run the real tools on your files once and keep each call + its real result:
       python training/private_samples.py run --workdir D:/models --files a.stp b.stp --out runs.jsonl
   (pipe_extract + mid / outer surface_extract per file; add --tools to choose)
2. turn the runs into chat samples with many ways of asking:
       python training/private_samples.py make --runs runs.jsonl --out my_models_train.jsonl
3. upload my_models_train.jsonl as a PRIVATE Kaggle dataset and attach it to the notebook: the kernel trains on every
   attached *.jsonl and keeps that model off GitHub.
"""
import argparse, json, os, random, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from shipbrain import agent   # noqa: E402

ASK = {
    ('pipe_extract', None): ['Find the pipes in {f}', 'Extract the piping from {f}', 'Pipe structure of {f}: sizes, bends and length?',
                             'Make a 1D pipe beam model from {f}', '{f} - list all pipes and elbows', 'How much pipe is in {f}?',
                             'Recognise the pipe runs in {f} and give me a Nastran model'],
    ('surface_extract', 'mid'): ['Extract the mid surface of {f}', 'Midsurface extraction for {f}', 'Make a mid-surface shell model of {f}',
                                 'Give me mid surfaces with thickness from {f}', '{f}: mid surface please, grouped by thickness',
                                 'Convert the plates of {f} to mid surfaces'],
    ('surface_extract', 'outer'): ['Extract the outer surface of {f}', 'Outer surface extraction for {f}', 'Give me the outer skin of {f}',
                                   '{f}: outer surfaces grouped by thickness'],
}
DEFAULT_JOBS = [('pipe_extract', {}), ('surface_extract', {'kind': 'mid'}), ('surface_extract', {'kind': 'outer'})]


def run(workdir, files, out, jobs=DEFAULT_JOBS):
    tools = agent.Tools(workdir)
    done = set()
    if os.path.exists(out):
        done = {json.dumps([json.loads(l)['name'], json.loads(l)['args']]) for l in open(out)}
    for f in files:
        for name, extra in jobs:
            args = {'file': os.path.basename(f), **extra}
            if json.dumps([name, args]) in done:
                continue
            t = time.time()
            res = tools.call(name, args)
            with open(out, 'a', encoding='utf-8') as fh:
                fh.write(json.dumps({'name': name, 'args': args, 'result': res, 'seconds': round(time.time() - t)}, default=str) + '\n')
            print(name, args, round(time.time() - t), 's', (res.get('plain_english') or res.get('error', ''))[:200], flush=True)


def make(runs, out, per_run=6, seed=0):
    r = random.Random(seed)
    tools = agent.Tools(os.path.dirname(os.path.abspath(out)) or '.')
    sysmsg = {'role': 'system', 'content': agent.system_prompt(tools)}
    n = 0
    with open(out, 'w', encoding='utf-8') as fh:
        uniq = {}
        for line in open(runs, encoding='utf-8'):                 # the same call twice: keep the last result
            x = json.loads(line)
            uniq[json.dumps([x['name'], x['args']], sort_keys=True)] = x
        for x in uniq.values():
            res = x['result']
            if 'error' in res or not res.get('plain_english'):
                continue
            key = (x['name'], x['args'].get('kind') if x['name'] == 'surface_extract' else None)
            asks = ASK.get(key)
            if not asks:
                continue
            for q in r.sample(asks, min(per_run, len(asks))):
                msgs = [sysmsg, {'role': 'user', 'content': q.format(f=x['args']['file'])},
                        {'role': 'assistant', 'content': '```tool\n' + json.dumps({'name': x['name'], 'args': x['args']}) + '\n```'},
                        {'role': 'user', 'content': f"TOOL_RESULT {x['name']}: " + agent.compact_result(res)},
                        {'role': 'assistant', 'content': res['plain_english']}]
                fh.write(json.dumps({'task': 'private_' + x['name'], 'messages': msgs}) + '\n')
                n += 1
    print(out, n, 'samples')
    return n


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    a1 = sub.add_parser('run')
    a1.add_argument('--workdir', required=True)
    a1.add_argument('--files', nargs='+', required=True)
    a1.add_argument('--out', default='runs.jsonl')
    a2 = sub.add_parser('make')
    a2.add_argument('--runs', required=True)
    a2.add_argument('--out', default='my_models_train.jsonl')
    a2.add_argument('--per-run', type=int, default=6)
    a = ap.parse_args(argv)
    if a.cmd == 'run':
        run(a.workdir, a.files, a.out)
    else:
        make(a.runs, a.out, a.per_run)


if __name__ == '__main__':
    main()
