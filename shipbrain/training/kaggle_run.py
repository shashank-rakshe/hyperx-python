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


def watch(a):
    while True:
        s = run('kernels', 'status', f'{user()}/{SLUG}')
        print(time.strftime('%H:%M'), s, flush=True)
        if any(k in s.lower() for k in ('complete', 'error', 'cancel')):
            break
        time.sleep(300)


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=['start', 'status', 'watch', 'fetch'])
    ap.add_argument('--base', default='unsloth/Qwen3-4B-Instruct-2507')
    ap.add_argument('--n', type=int, default=4000)
    ap.add_argument('--dataset', action='append', help='your PRIVATE Kaggle dataset with rules_index.json, e.g. user/ship-rules')
    ap.add_argument('--out', default='kaggle_out')
    a = ap.parse_args()
    {'start': start, 'status': status, 'watch': watch, 'fetch': fetch}[a.cmd](a)
