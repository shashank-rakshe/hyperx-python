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


def sh(cmd):
    print('$', cmd, flush=True)
    r = subprocess.run(cmd, shell=True)
    if r.returncode:
        raise SystemExit(f'failed: {cmd}')


os.chdir('/kaggle/working')
sh(f'git clone -b {BRANCH} --depth 1 {REPO} src')
os.chdir('/kaggle/working/src/shipbrain')
sh('pip -q install unsloth scipy pyNastran ezdxf pdfplumber pypdfium2 pillow')
sh('pip -q install cadquery || echo "cadquery not installed: CAD tasks skipped"')
rules = glob.glob('/kaggle/input/*/rules_index.json')          # optional PRIVATE Kaggle dataset you attach yourself
extra = f'--knowledge {rules[0]}' if rules else ''
sh(f'python training/make_dataset.py --n {N_TRAIN} --eval-n {N_EVAL} --out data/train.jsonl --eval-out data/eval.jsonl {extra}')
sh(f'python training/evaluate.py --local {BASE} --data data/eval.jsonl --limit {EVAL_LIMIT} --out /kaggle/working/eval_before.json')
sh(f'python training/finetune.py --data data/train.jsonl --base {BASE} --out /kaggle/working/shipbrain_model --quant q4_k_m')
sh(f'python training/evaluate.py --local /kaggle/working/shipbrain_model/lora --data data/eval.jsonl --limit {EVAL_LIMIT} --out /kaggle/working/eval_after.json')
if DRAFT:      # same data, 1 epoch: the draft learns the tool format, so the main model accepts more of its guesses
    sh(f'EPOCHS=1 python training/finetune.py --data data/train.jsonl --base {DRAFT} --out /kaggle/working/draft_model --quant q8_0')
    for f in glob.glob('/kaggle/working/draft_model/*.gguf'):
        shutil.move(f, '/kaggle/working/' + os.path.basename(f).replace('shipbrain-', 'shipbrain-draft-'))
    shutil.rmtree('/kaggle/working/draft_model', ignore_errors=True)
for f in glob.glob('/kaggle/working/shipbrain_model/*.gguf'):
    shutil.move(f, '/kaggle/working/' + os.path.basename(f))
shutil.rmtree('/kaggle/working/shipbrain_model/ckpt', ignore_errors=True)
summary = {f: json.load(open('/kaggle/working/' + f))['total'] for f in ('eval_before.json', 'eval_after.json')}
json.dump(summary, open('/kaggle/working/summary.json', 'w'), indent=1)
print('SUMMARY', summary, flush=True)
try:
    from kaggle_secrets import UserSecretsClient
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
