"""
Runs on a FREE Kaggle GPU (T4/P100): data -> score base model -> QLoRA fine-tune -> score again -> GGUF.
Pushed and watched by training/kaggle_run.py. Outputs land in /kaggle/working (downloadable from the Kaggle page or by
`kaggle kernels output`). If you attach a Kaggle secret named HF_TOKEN (Add-ons -> Secrets), the GGUF is also uploaded
to a PRIVATE Hugging Face repo <your-name>/shipbrain-gguf.
Settings come from env-style constants below (kaggle_run.py rewrites them).
"""
import glob, json, os, shutil, subprocess, sys

BASE = 'unsloth/Qwen3-1.7B'        # fast on a CPU; 'unsloth/Qwen3-4B-Instruct-2507' = better answers, ~2x slower
DRAFT = 'unsloth/Qwen3-0.6B'      # tiny draft model for speculative decoding on the CPU ('' = skip)
N_TRAIN = 4000
N_EVAL = 200
EVAL_LIMIT = 60
BRANCH = 'claude/new-session-qpeo6g'
REPO = 'https://github.com/shashank-rakshe/hyperx-python.git'


GH_REPO = 'shashank-rakshe/hyperx-python'
STATUS_BRANCH = 'kaggle-runs'          # progress, log tail and scores are written here (needs Kaggle secret GH_TOKEN)
UPLOAD_MODEL = True                    # also attach the GGUF files to a GitHub release (public repo -> public model)
LOG = '/kaggle/working/run.log'
RUN_ID = __import__('time').strftime('%Y%m%d-%H%M')

try:
    from kaggle_secrets import UserSecretsClient
    GH_TOKEN = UserSecretsClient().get_secret('GH_TOKEN')
except Exception:
    GH_TOKEN = None


def gh(method, url, body=None, raw=None, ctype='application/json'):
    import urllib.request
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(url if url.startswith('http') else 'https://api.github.com' + url, data=data, method=method,
                                 headers={'Authorization': 'Bearer ' + GH_TOKEN, 'Accept': 'application/vnd.github+json',
                                          'Content-Type': ctype, 'User-Agent': 'shipbrain-kaggle'})
    with urllib.request.urlopen(req, timeout=3600) as r:
        t = r.read()
        return json.loads(t) if t else {}


def put_file(path, text):
    """create/update one file on the status branch (branch is created from the code branch if missing)"""
    import base64, urllib.error
    try:
        gh('GET', f'/repos/{GH_REPO}/git/ref/heads/{STATUS_BRANCH}')
    except urllib.error.HTTPError:
        sha = gh('GET', f'/repos/{GH_REPO}/git/ref/heads/{BRANCH}')['object']['sha']
        gh('POST', f'/repos/{GH_REPO}/git/refs', {'ref': f'refs/heads/{STATUS_BRANCH}', 'sha': sha})
    body = {'message': f'kaggle run {RUN_ID}: {path}', 'branch': STATUS_BRANCH, 'content': base64.b64encode(text.encode()).decode()}
    try:
        body['sha'] = gh('GET', f'/repos/{GH_REPO}/contents/{path}?ref={STATUS_BRANCH}')['sha']
    except urllib.error.HTTPError:
        pass
    gh('PUT', f'/repos/{GH_REPO}/contents/{path}', body)


def report(stage, extra=None):
    """write status + the last 150 log lines to GitHub so the run can be followed without opening Kaggle"""
    if not GH_TOKEN:
        return
    try:
        tail = ''.join(open(LOG, errors='replace').readlines()[-150:]) if os.path.exists(LOG) else ''
        st = {'run': RUN_ID, 'stage': stage, 'time_utc': __import__('time').strftime('%Y-%m-%d %H:%M', __import__('time').gmtime()),
              'base': BASE, 'n_train': N_TRAIN, **(extra or {})}
        put_file(f'kaggle_runs/{RUN_ID}/status.json', json.dumps(st, indent=1))
        put_file(f'kaggle_runs/{RUN_ID}/log_tail.txt', tail)
        put_file('kaggle_runs/latest.json', json.dumps(st, indent=1))
    except Exception as e:
        print('(could not report to GitHub:', e, ')', flush=True)


def sh(cmd, required=True):
    print('$', cmd, flush=True)
    open(LOG, 'a').write(f'$ {cmd}\n')
    r = subprocess.run(f'set -o pipefail; ( {cmd} ) 2>&1 | tee -a {LOG}', shell=True, executable='/bin/bash')
    if r.returncode and required:
        report('FAILED: ' + cmd[:80])
    if r.returncode:
        if required:
            raise SystemExit(f'failed: {cmd}')
        print(f'(optional step failed, continuing): {cmd}', flush=True)
    return r.returncode == 0


os.chdir('/kaggle/working')
report('started')
sh(f'git clone -b {BRANCH} --depth 1 {REPO} src')
os.chdir('/kaggle/working/src/shipbrain')
sh('pip -q install unsloth scipy pyNastran ezdxf pdfplumber pypdfium2 pillow')
sh('pip -q install cadquery || echo "cadquery not installed: CAD tasks skipped"')
report('installing done, making training data')
rules = glob.glob('/kaggle/input/*/rules_index.json')          # optional PRIVATE Kaggle dataset you attach yourself
extra = f'--knowledge {rules[0]}' if rules else ''
sh(f'python training/make_dataset.py --n {N_TRAIN} --eval-n {N_EVAL} --out data/train.jsonl --eval-out data/eval.jsonl {extra}')
if not sh('python training/repo_tasks.py --packs packs --out data/repo_train.jsonl --eval-out data/repo_eval.jsonl', required=False):
    open('data/repo_train.jsonl', 'w').close()          # knowledge of shared repos is a bonus, not a blocker
sh('cat data/repo_eval.jsonl >> data/eval.jsonl', required=False)
report('scoring the base model')
sh(f'python training/evaluate.py --local {BASE} --data data/eval.jsonl --limit {EVAL_LIMIT} --out /kaggle/working/eval_before.json', required=False)
report('training the main model')
sh(f'python training/finetune.py --data data/train.jsonl data/repo_train.jsonl --base {BASE} --out /kaggle/working/shipbrain_model --quant q4_k_m')
report('scoring the trained model')
sh(f'python training/evaluate.py --local /kaggle/working/shipbrain_model/lora --data data/eval.jsonl --limit {EVAL_LIMIT} --out /kaggle/working/eval_after.json', required=False)
if DRAFT:
    report('training the small draft model')
if DRAFT:      # same data, 1 epoch: the draft learns the tool format, so the main model accepts more of its guesses
    sh(f'EPOCHS=1 python training/finetune.py --data data/train.jsonl data/repo_train.jsonl --base {DRAFT} --out /kaggle/working/draft_model --quant q8_0', required=False)
    for f in glob.glob('/kaggle/working/draft_model/*.gguf'):
        shutil.move(f, '/kaggle/working/' + os.path.basename(f).replace('shipbrain-', 'shipbrain-draft-'))
    shutil.rmtree('/kaggle/working/draft_model', ignore_errors=True)
for f in glob.glob('/kaggle/working/shipbrain_model/*.gguf'):
    shutil.move(f, '/kaggle/working/' + os.path.basename(f))
shutil.rmtree('/kaggle/working/shipbrain_model/ckpt', ignore_errors=True)
summary = {f: json.load(open('/kaggle/working/' + f))['total'] for f in ('eval_before.json', 'eval_after.json')
           if os.path.exists('/kaggle/working/' + f)}
summary['model_files'] = sorted(os.path.basename(f) for f in glob.glob('/kaggle/working/*.gguf'))
json.dump(summary, open('/kaggle/working/summary.json', 'w'), indent=1)
print('SUMMARY', summary, flush=True)
report('finished training, uploading', {'summary': summary})
if GH_TOKEN and UPLOAD_MODEL:
    try:
        rel = gh('POST', f'/repos/{GH_REPO}/releases', {'tag_name': f'shipbrain-model-{RUN_ID}', 'target_commitish': BRANCH,
                                                        'name': f'ShipBrain model {RUN_ID}', 'body': json.dumps(summary, indent=1), 'prerelease': True})
        up = rel['upload_url'].split('{')[0]
        for f in glob.glob('/kaggle/working/*.gguf'):
            gh('POST', f'{up}?name={os.path.basename(f)}', raw=open(f, 'rb').read(), ctype='application/octet-stream')
        summary['release'] = rel['html_url']
        print('model uploaded to', rel['html_url'], flush=True)
    except Exception as e:
        print('(model upload to GitHub failed:', e, ')', flush=True)
try:
    token = UserSecretsClient().get_secret('HF_TOKEN')
except Exception:
    token = None
if token:
    from huggingface_hub import HfApi, create_repo
    api = HfApi(token=token)
    repo = api.whoami()['name'] + '/shipbrain-gguf'
    create_repo(repo, private=True, exist_ok=True, token=token)
    for f in glob.glob('/kaggle/working/*.gguf') + ['/kaggle/working/summary.json']:
        api.upload_file(path_or_fileobj=f, path_in_repo=os.path.basename(f), repo_id=repo)
    print('uploaded to https://huggingface.co/' + repo)
shutil.rmtree('/kaggle/working/src', ignore_errors=True)
report('ALL DONE', {'summary': summary})
print('ALL DONE - open the Output tab and download shipbrain-q4_k_m.gguf (and summary.json)', flush=True)
