"""
Start / watch / download a ShipBrain training run on a free Kaggle GPU, from any PC (or from the assistant's session).

Needs: a Kaggle account with a VERIFIED PHONE number (Kaggle only gives GPU + internet to verified accounts) and an
API token: Kaggle -> Settings -> API -> "Create New Token" -> set KAGGLE_USERNAME and KAGGLE_KEY (or put kaggle.json in
~/.kaggle/). Then:
    pip install kaggle
    python training/kaggle_run.py start  [--base unsloth/Qwen3-1.7B] [--n 4000]
    python training/kaggle_run.py status
    python training/kaggle_run.py fetch   -> ./kaggle_out/ (GGUF, eval_before.json, eval_after.json, log)
Free quota: about 30 GPU hours per week, one run may last up to 12 hours.
"""
import argparse, json, os, re, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
SLUG = 'shipbrain-train'


def user():
    u = os.environ.get('KAGGLE_USERNAME')
    if not u:
        p = os.path.expanduser('~/.kaggle/kaggle.json')
        if os.path.exists(p):
            u = json.load(open(p))['username']
    if not u:
        sys.exit('set KAGGLE_USERNAME and KAGGLE_KEY (Kaggle -> Settings -> API -> Create New Token)')
    return u


def run(*args):
    r = subprocess.run(['kaggle', *args], capture_output=True, text=True)
    out = (r.stdout + r.stderr).strip()
    if r.returncode:
        sys.exit(out)
    return out


def start(a):
    d = tempfile.mkdtemp()
    src = open(os.path.join(HERE, 'kaggle', 'kernel.py')).read()
    src = re.sub(r"^BASE = .*$", f"BASE = {a.base!r}", src, flags=re.M)
    src = re.sub(r"^N_TRAIN = .*$", f"N_TRAIN = {a.n}", src, flags=re.M)
    src = re.sub(r"^DRAFT = .*$", f"DRAFT = {a.draft!r}", src, flags=re.M)
    if os.environ.get('SB_BRANCH'):
        src = re.sub(r"^BRANCH = .*$", f"BRANCH = {os.environ['SB_BRANCH']!r}", src, flags=re.M)
    open(os.path.join(d, 'kernel.py'), 'w').write(src)
    meta = {'id': f'{user()}/{SLUG}', 'title': SLUG, 'code_file': 'kernel.py', 'language': 'python', 'kernel_type': 'script',
            'is_private': True, 'enable_gpu': True, 'enable_internet': True, 'dataset_sources': a.dataset or [],
            'competition_sources': [], 'kernel_sources': []}
    json.dump(meta, open(os.path.join(d, 'kernel-metadata.json'), 'w'), indent=1)
    print(run('kernels', 'push', '-p', d))
    shutil.rmtree(d)


def status(a):
    print(run('kernels', 'status', f'{user()}/{SLUG}'))


def fetch(a):
    os.makedirs(a.out, exist_ok=True)
    print(run('kernels', 'output', f'{user()}/{SLUG}', '-p', a.out))
    s = os.path.join(a.out, 'summary.json')
    if os.path.exists(s):
        print(open(s).read())


def auto(a):
    """used by the GitHub workflow: read the request, start the run, wait (up to ~5.5 h), download the small result files"""
    req = json.load(open(a.request)) if a.request and os.path.exists(a.request) else {}
    a.base = req.get('base', a.base)
    a.n = int(req.get('n', a.n))
    a.draft = req.get('draft', a.draft)
    a.dataset = req.get('datasets') or a.dataset
    print('request:', req, flush=True)
    start(a)
    time.sleep(120)
    t0, state = time.time(), ''
    while time.time() - t0 < 5.4 * 3600:
        try:
            state = run('kernels', 'status', f'{user()}/{SLUG}')
        except SystemExit as e:
            state = str(e)
        print(time.strftime('%H:%M'), state, flush=True)
        if any(k in state.lower() for k in ('complete', 'error', 'cancel')):
            break
        time.sleep(300)
    os.makedirs(a.out, exist_ok=True)
    open(os.path.join(a.out, 'status.txt'), 'w').write(state + '\n')
    if 'complete' in state.lower() or 'error' in state.lower():
        tmp = tempfile.mkdtemp()
        try:
            run('kernels', 'output', f'{user()}/{SLUG}', '-p', tmp)
        except SystemExit as e:
            print('download failed:', e)
        for f in os.listdir(tmp):                      # only the small files: the model stays on Kaggle (private)
            if f.endswith(('.json', '.log', '.txt')):
                shutil.copy(os.path.join(tmp, f), a.out)
        for root, _, fs in os.walk(tmp):
            for f in fs:
                if f.endswith('.log') and not os.path.exists(os.path.join(a.out, f)):
                    shutil.copy(os.path.join(root, f), a.out)
    print('final state:', state)


def watch(a):
    while True:
        s = run('kernels', 'status', f'{user()}/{SLUG}')
        print(time.strftime('%H:%M'), s, flush=True)
        if any(k in s.lower() for k in ('complete', 'error', 'cancel')):
            break
        time.sleep(300)


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=['start', 'status', 'watch', 'fetch', 'auto'])
    ap.add_argument('--request', help='JSON with base / n / draft / datasets (auto mode)')
    ap.add_argument('--base', default='unsloth/Qwen3-1.7B')
    ap.add_argument('--draft', default='unsloth/Qwen3-0.6B', help="draft model for speculative decoding ('' = none)")
    ap.add_argument('--n', type=int, default=4000)
    ap.add_argument('--dataset', action='append', help='your PRIVATE Kaggle dataset with rules_index.json, e.g. user/ship-rules')
    ap.add_argument('--out', default='kaggle_out')
    a = ap.parse_args()
    {'start': start, 'status': status, 'watch': watch, 'fetch': fetch, 'auto': auto}[a.cmd](a)
