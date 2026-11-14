"""
Data check before the slow steps (about 1 minute, no GPU): every training file the trainer will read is parsed line by line and each row is converted exactly the way finetune.py converts it.
A damaged file is found here, in the first minutes of a run, not after the model has been loaded and scored.

    python training/preflight.py --data data/train.jsonl data/repo_train.jsonl ...     (exit 1 when more than 1 % of the rows fail)
"""
import argparse, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--data', nargs='+', required=True)
    ap.add_argument('--max-bad', type=float, default=0.01)
    a = ap.parse_args(argv)
    import importlib.util
    spec = importlib.util.spec_from_file_location('ft', os.path.join(HERE, 'finetune.py'))
    ft = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ft)
    tot = bad = ok = 0
    per = {}
    empty = []
    for f in a.data:
        if not os.path.exists(f) or os.path.getsize(f) == 0:
            empty.append(f)
            continue
        root = os.path.dirname(os.path.abspath(f))
        for i, l in enumerate(open(f, encoding='utf-8'), 1):
            if not l.strip():
                continue
            tot += 1
            try:
                d = json.loads(l)
                if ('good' in d and not d['good']) or ('chosen' in d and 'rejected' in d):
                    continue
                if d.get('messages'):
                    d['messages'] = ft.with_system(d['messages'])
                ft._vl_messages(d, root)
                ok += 1
            except Exception as e:
                bad += 1
                per.setdefault(f, []).append((i, type(e).__name__ + ': ' + str(e)[:60]))
    print(f'PREFLIGHT: {len(a.data)} files, {tot} rows, {ok} fine, {bad} damaged; empty files: {empty}', flush=True)
    for f, v in per.items():
        print(f'  {f}: {len(v)} damaged, first: line {v[0][0]} {v[0][1]}', flush=True)
    if tot and bad / tot > a.max_bad:
        print('PREFLIGHT FAILED: more than {:.0%} of the rows are damaged: fix the data before training'.format(a.max_bad), flush=True)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
