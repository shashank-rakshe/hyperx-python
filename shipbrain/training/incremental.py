"""
Train only on NEW data: remember which training samples a model has already learned, and on the next run give the model only the
samples it has not seen (plus a small replay of old ones so it does not forget), continuing from its saved LoRA adapter.

  python training/incremental.py plan   --data 'data/*_train.jsonl' --state state/manifest.json.gz --base <base> [--replay 0.1]
        -> rewrites the files in place with the new samples + replay (originals in data_full/), prints how many are new
  python training/incremental.py commit --data 'data_full/*_train.jsonl' --state state/manifest.json.gz --base <base> --run <id>
        -> marks every sample of the (full) data as learned
  python training/incremental.py fetch  --dest state            (Kaggle input folder `shipbrain_state`, else private Hugging Face repo <you>/shipbrain-state)
  python training/incremental.py push   --src state             (manifest + LoRA adapter to the private Hugging Face repo)

A sample is identified by a hash of its content (so the same sample is never learned twice, however the files are named or ordered).
The manifest also stores the base model: a different base means everything is new again (full training).
"""
import argparse, glob, gzip, hashlib, json, os, shutil, sys, time

VOLATILE = ('_root',)


def key(line):
    try:
        d = json.loads(line)
        for k in VOLATILE:
            d.pop(k, None)
        s = json.dumps(d, sort_keys=True, ensure_ascii=False, separators=(',', ':'))
    except ValueError:
        s = line.strip()
    return hashlib.sha1(s.encode('utf-8')).hexdigest()[:16]


def files_of(patterns):
    out = []
    for p in patterns:
        out += sorted(glob.glob(p))
    return [f for f in dict.fromkeys(out) if 'eval' not in os.path.basename(f).lower() and os.path.isfile(f) and f.endswith('.jsonl')]


def load(state):
    if state and os.path.exists(state):
        return json.load(gzip.open(state, 'rt'))
    return {'format': 1, 'base': None, 'runs': [], 'keys': []}


def save(m, state):
    os.makedirs(os.path.dirname(os.path.abspath(state)), exist_ok=True)
    m['keys'] = sorted(set(m['keys']))
    with gzip.open(state, 'wt') as f:
        json.dump(m, f, separators=(',', ':'))


def plan(files, state, base, replay=0.1, keep_dir='data_full', inplace=True):
    """-> stats; with inplace the files are replaced by new + replay samples (originals copied to keep_dir)"""
    m = load(state)
    if m['base'] and base and m['base'] != base:
        return {'mode': 'full', 'why': f"the base model changed ({m['base']} -> {base})", 'new': None, 'old': None}
    seen = set(m['keys'])
    if not seen:
        return {'mode': 'full', 'why': 'no earlier run is recorded', 'new': None, 'old': None}
    cut = int(round(float(replay) * 1000))
    new = old = replayed = 0
    per = {}
    os.makedirs(keep_dir, exist_ok=True)
    for f in files:
        keep, n_new, n_old = [], 0, 0
        for line in open(f, encoding='utf-8'):
            if not line.strip():
                continue
            k = key(line)
            if k in seen:
                n_old += 1
                if int(k[:6], 16) % 1000 < cut:          # a fixed share of the old samples, chosen by hash: same ones every time
                    keep.append(line)
                    replayed += 1
            else:
                n_new += 1
                keep.append(line)
        per[os.path.basename(f)] = {'new': n_new, 'old': n_old}
        new += n_new
        old += n_old
        if inplace:
            shutil.copy(f, os.path.join(keep_dir, os.path.basename(f)))
            open(f, 'w', encoding='utf-8').writelines(keep if keep[-1:] and keep[-1].endswith('\n') else [x if x.endswith('\n') else x + '\n' for x in keep])
    return {'mode': 'incremental', 'new': new, 'old': old, 'replayed': replayed, 'files': {k: v for k, v in per.items() if v['new']}}


def commit(files, state, base, run):
    m = load(state)
    n0 = len(set(m['keys']))
    keys = set(m['keys'])
    for f in files:
        for line in open(f, encoding='utf-8'):
            if line.strip():
                keys.add(key(line))
    m.update(base=base, keys=list(keys))
    m['runs'].append({'run': run, 'time_utc': time.strftime('%Y-%m-%d %H:%M', time.gmtime()), 'added': len(keys) - n0, 'total': len(keys)})
    save(m, state)
    return m['runs'][-1]


def _hf():
    from huggingface_hub import HfApi
    tok = os.environ.get('HF_TOKEN')
    if not tok:
        try:
            from kaggle_secrets import UserSecretsClient
            tok = UserSecretsClient().get_secret('HF_TOKEN')
        except Exception:
            tok = None
    if not tok:
        return None, None
    api = HfApi(token=tok)
    return api, api.whoami()['name'] + '/shipbrain-state'


def fetch(dest):
    """the previous run's state -> dest/manifest.json.gz and dest/lora/. Returns True when found."""
    os.makedirs(dest, exist_ok=True)
    for man in sorted(glob.glob('/kaggle/input/**/shipbrain_state/manifest.json.gz', recursive=True)):
        src = os.path.dirname(man)
        shutil.copytree(src, dest, dirs_exist_ok=True)
        return os.path.exists(os.path.join(dest, 'lora', 'adapter_config.json'))
    api, repo = _hf()
    if not api:
        return False
    try:
        from huggingface_hub import snapshot_download
        snapshot_download(repo, local_dir=dest, token=api.token)
    except Exception as e:
        print('(no saved state on Hugging Face:', type(e).__name__, ')')
        return False
    return os.path.exists(os.path.join(dest, 'manifest.json.gz')) and os.path.exists(os.path.join(dest, 'lora', 'adapter_config.json'))


def push(src):
    api, repo = _hf()
    if not api:
        raise SystemExit('no HF_TOKEN: attach the Kaggle secret HF_TOKEN (a write token) so the model state can be kept for the next run')
    api.create_repo(repo, private=True, exist_ok=True)
    api.upload_folder(folder_path=src, repo_id=repo, commit_message='ShipBrain state ' + time.strftime('%Y%m%d-%H%M'))
    return repo


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=['plan', 'commit', 'fetch', 'push'])
    ap.add_argument('--data', nargs='+', default=['data/*_train.jsonl', 'data/train.jsonl', 'data/dpo_pairs.jsonl'])
    ap.add_argument('--state', default='state/manifest.json.gz')
    ap.add_argument('--base', default='')
    ap.add_argument('--replay', type=float, default=0.1)
    ap.add_argument('--run', default='')
    ap.add_argument('--dest', default='state')
    ap.add_argument('--src', default='state')
    ap.add_argument('--keep-dir', default='data_full')
    a = ap.parse_args(argv)
    if a.cmd == 'plan':
        r = plan(files_of(a.data), a.state, a.base, a.replay, a.keep_dir)
    elif a.cmd == 'commit':
        r = commit(files_of(a.data), a.state, a.base, a.run)
    elif a.cmd == 'fetch':
        r = {'found': fetch(a.dest)}
    else:
        r = {'repo': push(a.src)}
    print(json.dumps(r))
    return r


if __name__ == '__main__':
    main()
