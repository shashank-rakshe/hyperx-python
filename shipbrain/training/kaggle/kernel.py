"""
Runs on a FREE Kaggle GPU (T4/P100): data -> score base model -> QLoRA fine-tune -> score again -> GGUF.
Pushed and watched by training/kaggle_run.py. Outputs land in /kaggle/working (downloadable from the Kaggle page or by
`kaggle kernels output`). If you attach a Kaggle secret named HF_TOKEN (Add-ons -> Secrets), the GGUF is also uploaded
to a PRIVATE Hugging Face repo <your-name>/shipbrain-gguf.
Settings come from env-style constants below (kaggle_run.py rewrites them).
"""
import glob, json, os, shutil, subprocess, sys
os.environ['PYTHONUNBUFFERED'] = '1'       # every step's output reaches the Kaggle log at once (otherwise it appears only when the step ends)

BASE = 'unsloth/Qwen3-VL-4B-Instruct'   # FIXED base model: read again from training/base_model.json after the clone
DRAFT = 'unsloth/Qwen3-0.6B'           # tiny draft model for speculative decoding on the CPU ('' = skip)
N_TRAIN = 4000
N_EVAL = 200
N_TRAIN = int(os.environ.get('SB_N_TRAIN', N_TRAIN))      # synthetic samples from make_dataset (smaller = faster)
EVAL_LIMIT = 60
BRANCH = 'claude/new-session-qpeo6g'
REPO = 'https://github.com/shashank-rakshe/hyperx-python.git'


GH_REPO = 'shashank-rakshe/hyperx-python'
STATUS_BRANCH = 'kaggle-runs'          # progress, log tail and scores are written here (needs Kaggle secret GH_TOKEN)
UPLOAD_MODEL = True                    # also attach the GGUF files to a GitHub release (public repo -> public model)
LOG = '/kaggle/working/run.log'
RUN_ID = __import__('time').strftime('%Y%m%d-%H%M')
T0 = __import__('time').time()
BUDGET_H = float(os.environ.get('SB_BUDGET_H', 11))   # Kaggle stops a session at 12 h: optional last steps (draft model, speed measurement) are skipped when this much time is already used
CURRENT = ['starting']


def _heartbeat():
    import time
    while True:
        time.sleep(300)
        print(f'[heartbeat] {hours() * 60:.0f} min in, current step: {CURRENT[0][:110]}', flush=True)


__import__('threading').Thread(target=_heartbeat, daemon=True).start()


# DATA ON A CPU NOTEBOOK (no GPU quota): run once with  SB_DATA_ONLY=1  in a notebook WITHOUT accelerator; it writes shipbrain_train_data/ to its Output.
# Then attach that notebook's output as Input of the GPU notebook: the data steps are skipped and the GPU run only trains.
DATA_ONLY = os.environ.get('SB_DATA_ONLY') == '1'
PREBUILT = sorted(glob.glob('/kaggle/input/**/shipbrain_train_data/data_ready.flag', recursive=True))


def dsh(cmd, required=True, limit=None):
    """a data-making step: skipped (counted as done) when the data came ready-made from the CPU notebook"""
    return True if PREBUILT else sh(cmd, required, limit)


def hours():
    return (__import__('time').time() - T0) / 3600

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


STEP_LIMIT = int(os.environ.get('SB_STEP_LIMIT', 2400))     # seconds: an optional step that runs longer is stopped and skipped (one hung data step must never eat the GPU quota)


def sh(cmd, required=True, limit=None):
    print('$', cmd, flush=True)
    CURRENT[0] = cmd
    open(LOG, 'a').write(f'$ {cmd}\n')
    if limit is None and not required:
        limit = STEP_LIMIT
    if limit:
        import shlex
        cmd = f'timeout -k 20 {int(limit)} bash -c {shlex.quote(cmd)}'
    t0 = __import__('time').time()
    r = subprocess.run(f'set -o pipefail; ( {cmd} ) 2>&1 | tee -a {LOG}', shell=True, executable='/bin/bash')
    print(f'   ({__import__("time").time() - t0:.0f} s, exit {r.returncode})', flush=True)
    if r.returncode and required:
        report('FAILED: ' + cmd[:80])
    if r.returncode:
        if required:
            raise SystemExit(f'failed: {cmd}')
        print(f'(optional step failed, continuing): {cmd}', flush=True)
    return r.returncode == 0


# SB_FAST=1: for a nearly used-up weekly quota: 1 epoch, fewer scoring samples, no draft model, no speed measurement (about half the GPU time)
if os.environ.get('SB_FAST') == '1':
    os.environ.setdefault('EPOCHS', '1')
    os.environ.setdefault('SB_SERVING_PROFILE', '0')
    EVAL_LIMIT = 30
    DRAFT = ''
os.chdir('/kaggle/working')
report('started')
shutil.rmtree('/kaggle/working/src', ignore_errors=True)        # a re-run in the same session must not fail
sh(f'git clone -b {BRANCH} --depth 1 {REPO} src')
os.chdir('/kaggle/working/src/shipbrain')
sh('pip -q install unsloth scipy pyNastran ezdxf pdfplumber pypdfium2 pillow wasmtime pydantic duckdb networkx rapidocr-onnxruntime liteparse xsdata xmlschema msgpack pyyaml "langchain<1" "langchain-openai<1" "langchain-experimental<1" svglib rlPyCairo loguru')
sh('python -m shipbrain.polyglot setup awatif', required=False)        # Node packages for the copied TypeScript code
sh('pip -q install cadquery || echo "cadquery not installed: CAD tasks skipped"')
sh('(apt-get -qq install -y calculix-ccx >/dev/null 2>&1 || sudo apt-get -qq install -y calculix-ccx >/dev/null 2>&1) || echo "CalculiX not installed: surrogate tasks skipped"', required=False)
report('installing done, making training data')
# ---- PRIVATE data: attach your private Kaggle dataset(s) (Add Input -> Your Datasets); nothing else to change
rules = glob.glob('/kaggle/input/**/rules_index.json', recursive=True)
extra = f'--knowledge {rules[0]}' if rules else ''
PRIVATE_TRAIN = sorted(f for f in glob.glob('/kaggle/input/**/*.jsonl*', recursive=True)
                       if 'eval' not in os.path.basename(f).lower() and '/shipbrain_model' not in f)
PRIVATE_EVAL = sorted(f for f in glob.glob('/kaggle/input/**/*eval*.jsonl*', recursive=True))
# ---- class society rules (copyright of each society -> private): download the free rule books here (SB_CLASS_RULES=0 to skip)
#      + any rule PDFs you attach (a Kaggle dataset with folders <society>/*.pdf, e.g. the ones that need a login)
_dm = sorted(glob.glob('/kaggle/input/**/shipbrain_data/manifest.json', recursive=True))
DATA = os.path.dirname(_dm[0]) if _dm else None       # the DATA notebook's output (training/kaggle/data_kernel.py), if attached
if DATA:
    print('data folder attached:', DATA, open(_dm[0]).read()[:1500], flush=True)
if os.environ.get('SB_CLASS_RULES', '1') != '0' and not PREBUILT and not (DATA and glob.glob(f'{DATA}/packs/class_rules_*.private.sbpack')):
    sh('python -m shipbrain.classrules download --out /tmp/class_rules_pdfs --max-files 80', required=False)
    for d in sorted(set(os.path.dirname(os.path.dirname(f)) for f in glob.glob('/kaggle/input/**/*.pdf', recursive=True)
                        if 'rule' in f.lower())):
        sh(f'cp -rn "{d}"/* /tmp/class_rules_pdfs/ 2>/dev/null', required=False)
    sh('python -m shipbrain.classrules build --pdfs /tmp/class_rules_pdfs --out packs', required=False)
OWN_PACKS = sorted(glob.glob('/kaggle/input/**/*.private.sbpack', recursive=True))
for f in OWN_PACKS:                      # your own code packs (built with repopack --own): knowledge + training, private model
    shutil.copy(f, 'packs/')
CLASS_PACKS = sorted(glob.glob('packs/class_rules_*.private.sbpack'))
PRIVATE = bool(rules or PRIVATE_TRAIN or OWN_PACKS or CLASS_PACKS)
if PRIVATE:
    UPLOAD_MODEL = False                 # a model trained on company data is never published (GitHub repo is public)
    print('private data attached:', rules + PRIVATE_TRAIN + PRIVATE_EVAL + OWN_PACKS + CLASS_PACKS, '- the model will NOT be uploaded to GitHub', flush=True)
# ---- the one fixed base model (training/base_model.json): every run trains it fresh on ALL the data, so nothing is lost
try:
    _cfg = json.load(open('training/base_model.json'))
    BASE, DRAFT = _cfg['base'], _cfg.get('draft', DRAFT)
    print('base model:', BASE, '| draft:', DRAFT, flush=True)
except Exception as e:
    print('(base_model.json not read:', e, ')', flush=True)
if os.environ.get('SB_FAST') == '1':
    DRAFT = ''                           # base_model.json would bring the draft model back
BASE_ID = BASE                           # the real base model name (BASE may become an adapter folder below)
# ---- continue from an older ShipBrain model: attach that run's output (Add Input -> Notebook Output) and start with
#      SB_CONTINUE=1 python k.py   (default: train fresh from the base model on ALL data - recommended, nothing is forgotten)
if os.environ.get('SB_CONTINUE') == '1':
    prev = sorted(glob.glob('/kaggle/input/**/shipbrain_model/lora/adapter_config.json', recursive=True))
    if prev:
        BASE = os.path.dirname(prev[-1])
        print('continuing from the older model:', BASE, flush=True)
    else:
        print('SB_CONTINUE=1 but no older model attached: training from the base model', flush=True)
FEEDBACK_FILES = sorted(f for f in glob.glob('/kaggle/input/**/*feedback*.jsonl', recursive=True))
if FEEDBACK_FILES:                       # the app's exported 👍 / 👎 (private dataset): liked conversations join the training data
    extra += ' ' + ' '.join(f'--feedback {f}' for f in FEEDBACK_FILES)
    PRIVATE = True; UPLOAD_MODEL = False  # user feedback is private: the model is never published
if PREBUILT:
    os.makedirs('data', exist_ok=True)
    sh(f'cp -r "{os.path.dirname(PREBUILT[-1])}/data/." data/')
    PRIVATE_TRAIN, PRIVATE_EVAL, OWN_PACKS = [], [], []          # the ready data already holds them (the glob above would also catch its own files)
    print('data steps skipped: ready-made data from', PREBUILT[-1], flush=True)
dsh(f'python training/make_dataset.py --n {N_TRAIN} --eval-n {N_EVAL} --out data/train.jsonl --eval-out data/eval.jsonl {extra}')
if not dsh('timeout 2700 python training/repo_tasks.py --packs packs --out data/repo_train.jsonl --eval-out data/repo_eval.jsonl', required=False):
    open('data/repo_train.jsonl', 'w').close()          # knowledge of shared repos is a bonus, not a blocker
# next.BREP.io's stl2step (Rust, used unchanged): STL inputs in the CAD training tasks
dsh('(command -v cargo || curl -sSf https://sh.rustup.rs | sh -s -- -y -q) && . $HOME/.cargo/env && '
   'python -c "from shipbrain import brep; brep.build()"', required=False)
# OpenPhysicsAI (copied whole): build it, run the examples that finish quickly, learn from the real records
if not dsh('python training/physics_tasks.py --out data/physics_train.jsonl --timeout 40', required=False):
    open('data/physics_train.jsonl', 'w').close()
# synthetic P&ID sheets with exact answer keys: teach the (vision) base model to read P&IDs into pid-to-kg's format
if not dsh('python training/synth_pid.py --n 400 --out data/synth_pid_train.jsonl --img-dir data/pid_images', required=False):
    open('data/synth_pid_train.jsonl', 'w').close()
# public P&ID drawing sets (real permitted facilities): downloaded here, prepared with pid-to-kg, learned from; never stored
if not dsh('python training/public_pids.py --out data/public_pid_train.jsonl --max-pages 4', required=False):
    open('data/public_pid_train.jsonl', 'w').close()
# construction drawings (ConstructDrawingAI's synthetic engine, non-commercial licence): pictures with exact answer keys
if not dsh('python training/construct_tasks.py --n 160 --out data/construct_train.jsonl --img-dir data/construct_images', required=False):
    open('data/construct_train.jsonl', 'w').close()
# real drawings with full answer keys: PID2Graph P&IDs (CC BY-SA) + CubiCasa5K floor plans (CC BY-NC); downloaded here
# made on GitHub by .github/workflows/shipbrain-data.yml (release data-latest): fetched here, nothing to attach by hand
dsh(f'curl -sfL -o /tmp/real_drawings.zip https://github.com/{GH_REPO}/releases/download/data-latest/shipbrain-real-drawings.zip '
   '&& unzip -qo /tmp/real_drawings.zip -d data && wc -l data/construct_real_train.jsonl', required=False)
dsh(f'curl -sfL -o /tmp/parsebench.zip https://github.com/{GH_REPO}/releases/download/data-latest/parsebench.zip '
   '&& unzip -qo /tmp/parsebench.zip -d data || true', required=False)   # ParseBench pages (only when its licence allows)
dsh('touch data/parsebench_train.jsonl', required=False)
if os.path.exists('data/construct_real_train.jsonl') and os.path.getsize('data/construct_real_train.jsonl') > 0:
    print('real drawing samples: from the GitHub release data-latest', flush=True)
elif not dsh('python training/construct_real.py --out data/construct_real_train.jsonl --img-dir data/construct_real_images'
          + (f' --data-root "{DATA}"' if DATA else ''), required=False):
    open('data/construct_real_train.jsonl', 'w').close()
# DEXPI P&IDs (pyDEXPI's real example P&IDs: summary, validation, pictures with exact tags) - made with pyDEXPI
# (Python 3.12+) and kept in the repo: training/data/dexpi_train.jsonl.gz + training/data/dexpi_images/
dsh('zcat training/data/dexpi_train.jsonl.gz > data/dexpi_train.jsonl && cp -r training/data/dexpi_images data/ '
   '|| touch data/dexpi_train.jsonl', required=False)
# DWSIM process simulations: made with the real simulator and kept in the repo (training/data/dwsim_train.jsonl.gz)
dsh('zcat training/data/dwsim_train.jsonl.gz > data/dwsim_train.jsonl || touch data/dwsim_train.jsonl', required=False)
# ReverseCAD STL -> STEP conversions (non-commercial licence): real runs, kept in the repo (training/data/reversecad_train.jsonl.gz)
dsh('zcat training/data/reversecad_train.jsonl.gz > data/reversecad_train.jsonl || touch data/reversecad_train.jsonl', required=False)
# cadmpeg native CAD reading (Apache-2.0) on its public CC0 / NIST specimens: real runs, kept in the repo
dsh('zcat training/data/cadmpeg_train.jsonl.gz > data/cadmpeg_train.jsonl || touch data/cadmpeg_train.jsonl', required=False)
# Rhino .3dm import with ShipBrain's own exact reader (rhino3dm, MIT): real conversions, kept in the repo
dsh('zcat training/data/rhino_train.jsonl.gz > data/rhino_train.jsonl || touch data/rhino_train.jsonl', required=False)
# NX Open journals with nxopentse (AGPL) + NX File Renamer (GPL): kept in the repo
dsh('zcat training/data/nx_train.jsonl.gz > data/nx_train.jsonl || touch data/nx_train.jsonl', required=False)
# CableDyn mooring lines and cables (Apache-2.0): real solver runs, kept in the repo
dsh('zcat training/data/cabledyn_train.jsonl.gz > data/cabledyn_train.jsonl || touch data/cabledyn_train.jsonl', required=False)
# TensorMesh topology optimisation and solid solves (Apache-2.0): real runs, kept in the repo
dsh('zcat training/data/tensormesh_train.jsonl.gz > data/tensormesh_train.jsonl || touch data/tensormesh_train.jsonl', required=False)
# VTracer scanned-drawing tracing (MIT): real runs, kept in the repo
dsh('zcat training/data/vtracer_train.jsonl.gz > data/vtracer_train.jsonl || touch data/vtracer_train.jsonl', required=False)
# ProcessPi pipe hydraulics (MIT): real runs, kept in the repo
dsh('zcat training/data/pipeflow_train.jsonl.gz > data/pipeflow_train.jsonl || touch data/pipeflow_train.jsonl', required=False)
# understanding users: ask when inputs are missing, messy units, design loops, recovery from tool errors (real runs)
dsh('zcat training/data/understanding_train.jsonl.gz > data/understanding_train.jsonl || touch data/understanding_train.jsonl', required=False)
# ShipBrain's own hex mesher: real meshing runs on solid parts, kept in the repo
dsh('zcat training/data/hexmesh_train.jsonl.gz > data/hexmesh_train.jsonl || touch data/hexmesh_train.jsonl', required=False)
# 2D drawings from plain words (dxf_draw / dxf_check): real runs, kept in the repo
dsh('zcat training/data/dxf_train.jsonl.gz > data/dxf_train.jsonl || touch data/dxf_train.jsonl', required=False)
dsh('zcat training/data/piperoute_train.jsonl.gz > data/piperoute_train.jsonl || touch data/piperoute_train.jsonl', required=False)
dsh('zcat training/data/centerline_train.jsonl.gz > data/centerline_train.jsonl || touch data/centerline_train.jsonl', required=False)
dsh('zcat training/data/connection_train.jsonl.gz > data/connection_train.jsonl || touch data/connection_train.jsonl', required=False)
dsh('zcat training/data/boltgroup_train.jsonl.gz > data/boltgroup_train.jsonl || touch data/boltgroup_train.jsonl', required=False)
dsh('zcat training/data/osoconn_train.jsonl.gz > data/osoconn_train.jsonl || touch data/osoconn_train.jsonl', required=False)
dsh('zcat training/data/xc_train.jsonl.gz > data/xc_train.jsonl || touch data/xc_train.jsonl', required=False)
dsh('zcat training/data/cbfem_train.jsonl.gz > data/cbfem_train.jsonl || touch data/cbfem_train.jsonl', required=False)
dsh('zcat training/data/pipestress_train.jsonl.gz > data/pipestress_train.jsonl || touch data/pipestress_train.jsonl', required=False)
dsh('zcat training/data/pulsation_train.jsonl.gz > data/pulsation_train.jsonl || touch data/pulsation_train.jsonl', required=False)
dsh('zcat training/data/parts_train.jsonl.gz > data/parts_train.jsonl || touch data/parts_train.jsonl', required=False)
dsh('zcat training/data/fvm_train.jsonl.gz > data/fvm_train.jsonl || touch data/fvm_train.jsonl', required=False)
dsh('zcat training/data/elmer_train.jsonl.gz > data/elmer_train.jsonl || touch data/elmer_train.jsonl', required=False)
dsh('zcat training/data/openfoam_train.jsonl.gz > data/openfoam_train.jsonl || touch data/openfoam_train.jsonl', required=False)
dsh('zcat training/data/vessel_train.jsonl.gz > data/vessel_train.jsonl || touch data/vessel_train.jsonl', required=False)
dsh('zcat training/data/hull_train.jsonl.gz > data/hull_train.jsonl || touch data/hull_train.jsonl', required=False)
dsh('zcat training/data/late_tools_train.jsonl.gz > data/late_tools_train.jsonl || touch data/late_tools_train.jsonl', required=False)   # propeller, Nastran, hull resistance / GZ / motions, blocks, frames, catamaran, HCM
# MOOSE plate checks made on GitHub in the official MOOSE image (release moose-latest)
dsh(f'curl -sSfL -o /tmp/moose_train.jsonl.gz https://github.com/{GH_REPO}/releases/download/moose-latest/moose_train.jsonl.gz'
   ' && zcat /tmp/moose_train.jsonl.gz > data/moose_train.jsonl || touch data/moose_train.jsonl', required=False)
# cad3dify's own drawing -> CadQuery -> render -> correct loop, in its own prompt format, on the verified CAD examples
if not dsh('python training/cad3dify_tasks.py --out data/cad3dify_train.jsonl --img-dir data/cad3dify_images', required=False):
    open('data/cad3dify_train.jsonl', 'w').close()
# class rules: IACS calculators + every rule section with a formula in the class rule packs (natural-language answers)
if not dsh('python training/class_rule_tasks.py --packs packs --out data/class_rule_train.jsonl', required=False):
    open('data/class_rule_train.jsonl', 'w').close()
# public OCX ship models (real CAD exports): fetched here, names removed, learned from; never stored
if not dsh('python training/ocx_samples.py --out data/ocx_train.jsonl --eval-out data/ocx_eval.jsonl', required=False):
    open('data/ocx_train.jsonl', 'w').close()
    open('data/ocx_eval.jsonl', 'w').close()
dsh('cat data/repo_eval.jsonl >> data/eval.jsonl', required=False)
dsh('cat data/ocx_eval.jsonl >> data/eval.jsonl', required=False)
def _plain(paths):
    out = []
    for f in paths:                                   # .jsonl.gz -> .jsonl next to the data folder
        if f.endswith('.gz'):
            import gzip
            dst = 'data/' + os.path.basename(f)[:-3]
            open(dst, 'w').write(gzip.open(f, 'rt').read())
            out.append(dst)
        else:
            dst = 'data/priv_' + os.path.basename(f)            # private files join data/ so the incremental plan sees them too
            shutil.copy(f, dst)
            out.append(dst)
    return out
PRIV = ' '.join(_plain(PRIVATE_TRAIN))
for f in _plain(PRIVATE_EVAL):
    sh(f'cat {f} >> data/eval.jsonl', required=False)
# ---- INCREMENTAL training: SB_MODE=auto (default) trains only on data the saved model has not seen yet (+ a small replay), continuing from its
#      saved LoRA adapter; falls back to full training when there is no saved state or the base model changed. SB_MODE=full: everything from scratch.
#      SB_MODE=new: like auto but stop with an error instead of falling back to full. SB_REPLAY=0.1 is the share of old samples mixed in (0 = only new).
MODE = os.environ.get('SB_MODE', 'auto')
REPLAY = os.environ.get('SB_REPLAY', '0.1')
INCREMENTAL = False
STATE = '/kaggle/working/state'
if MODE != 'full':
    sh(f'python training/incremental.py fetch --dest {STATE}', required=False)
    if os.path.exists(f'{STATE}/lora/adapter_config.json') and os.path.exists(f'{STATE}/manifest.json.gz'):
        r = subprocess.run(f'python training/incremental.py plan --state {STATE}/manifest.json.gz --base "{BASE_ID}" --replay {REPLAY}',
                           shell=True, capture_output=True, text=True)
        print(r.stdout, r.stderr, flush=True)
        try:
            PLAN = json.loads(r.stdout.strip().splitlines()[-1])
        except Exception:
            PLAN = {'mode': 'full', 'why': 'could not read the plan'}
        if PLAN.get('mode') == 'incremental':
            if PLAN['new'] == 0:
                report('nothing new to train', {'plan': PLAN})
                raise SystemExit('NOTHING NEW: every sample was learned before. Add data (repos, tasks, packs) and run again, or SB_MODE=full to retrain everything.')
            INCREMENTAL = True
            BASE = f'{STATE}/lora'                                  # continue from the saved adapter
            os.environ.setdefault('LR', '1e-4')                     # gentler: new data should add, not overwrite
            print(f"INCREMENTAL: {PLAN['new']} new samples + {PLAN['replayed']} replayed old ones ({PLAN['old']} already learned); continuing from the saved model", flush=True)
            report('incremental training', {'plan': PLAN})
        else:
            print('full training:', PLAN.get('why'), flush=True)
    elif MODE == 'new':
        raise SystemExit('SB_MODE=new but no saved model state found (Kaggle secret HF_TOKEN + one earlier finished run, or attach the dataset shipbrain_state)')
    else:
        print('no saved model state: full training on all data (this run saves the state for the next one)', flush=True)
if DATA_ONLY:
    os.makedirs('/kaggle/working/shipbrain_train_data', exist_ok=True)
    sh('rm -rf /kaggle/working/shipbrain_train_data/data && cp -r data /kaggle/working/shipbrain_train_data/data')
    open('/kaggle/working/shipbrain_train_data/data_ready.flag', 'w').write(RUN_ID)
    print('DATA READY in /kaggle/working/shipbrain_train_data - attach this notebook output to the GPU notebook', flush=True)
    report('data ready')
    raise SystemExit(0)
report('scoring the base model')
sh(f'python training/cad_eval.py --local {BASE} --limit 30 --out /kaggle/working/cad_eval_before.json', required=False)
sh(f'python training/evaluate.py --local {BASE} --data data/eval.jsonl --limit {EVAL_LIMIT} --out /kaggle/working/eval_before.json', required=False)
# the scorecard: hand-written realistic requests (complete / messy units / missing inputs / multi-step / no tool)
sh(f'python training/scorecard.py --local {BASE} --out /kaggle/working/scorecard_before.json', required=False)
report('making DPO preference pairs')
# tool calls instead of invented numbers, the tool's exact numbers, the caveats kept + your thumbs-down corrections
# (attach the app's feedback.jsonl in a PRIVATE Kaggle dataset; it is found here by its name)
FEEDBACK = ' '.join(FEEDBACK_FILES)
sh(f"python training/dpo_pairs.py --data 'data/*.jsonl' 'training/data/*.jsonl.gz' --feedback {FEEDBACK} --out data/dpo_pairs.jsonl --max 2000",
   required=False)
report('training the main model')
sh(f'MAX_LEN=6144 python training/finetune.py --data data/train.jsonl data/repo_train.jsonl data/public_pid_train.jsonl data/synth_pid_train.jsonl data/physics_train.jsonl data/ocx_train.jsonl data/construct_train.jsonl data/construct_real_train.jsonl data/cad3dify_train.jsonl data/class_rule_train.jsonl data/dexpi_train.jsonl data/dwsim_train.jsonl data/reversecad_train.jsonl data/cadmpeg_train.jsonl data/rhino_train.jsonl data/nx_train.jsonl data/cabledyn_train.jsonl data/tensormesh_train.jsonl data/vtracer_train.jsonl data/pipeflow_train.jsonl data/understanding_train.jsonl data/hexmesh_train.jsonl data/dxf_train.jsonl data/piperoute_train.jsonl data/centerline_train.jsonl data/connection_train.jsonl data/boltgroup_train.jsonl data/osoconn_train.jsonl data/xc_train.jsonl data/cbfem_train.jsonl data/pipestress_train.jsonl data/pulsation_train.jsonl data/parts_train.jsonl data/fvm_train.jsonl data/elmer_train.jsonl data/openfoam_train.jsonl data/vessel_train.jsonl data/hull_train.jsonl data/late_tools_train.jsonl data/moose_train.jsonl data/parsebench_train.jsonl {PRIV} --base {BASE} --out /kaggle/working/shipbrain_model --quant q4_k_m')
report('scoring the trained model')
sh('python training/cad_eval.py --local /kaggle/working/shipbrain_model/lora --limit 30 --out /kaggle/working/cad_eval_after.json', required=False)
sh(f'python training/evaluate.py --local /kaggle/working/shipbrain_model/lora --data data/eval.jsonl --limit {EVAL_LIMIT} --out /kaggle/working/eval_after.json', required=False)
sh('python training/scorecard.py --local /kaggle/working/shipbrain_model/lora --out /kaggle/working/scorecard_after.json', required=False)
if DRAFT and not INCREMENTAL and hours() > BUDGET_H - 2:
    print(f'draft model skipped: {hours():.1f} h used of the {BUDGET_H:g} h budget', flush=True)
    DRAFT = ''
if DRAFT and not INCREMENTAL:
    report('training the small draft model')
if DRAFT and not INCREMENTAL:      # same data, 1 epoch (skipped in incremental runs: it would see only the new data; the earlier draft file stays valid): the draft learns the tool format, so the main model accepts more of its guesses
    sh(f'DPO=0 EPOCHS=1 python training/finetune.py --data data/train.jsonl data/repo_train.jsonl data/public_pid_train.jsonl data/physics_train.jsonl data/ocx_train.jsonl {PRIV} --base {DRAFT} --out /kaggle/working/draft_model --quant q8_0', required=False)
    for f in glob.glob('/kaggle/working/draft_model*/**/*.gguf', recursive=True):
        shutil.move(f, '/kaggle/working/' + os.path.basename(f).replace('shipbrain-', 'shipbrain-draft-'))
    shutil.rmtree('/kaggle/working/draft_model', ignore_errors=True)
    shutil.rmtree('/kaggle/working/draft_model_gguf', ignore_errors=True)
for f in glob.glob('/kaggle/working/shipbrain_model*/**/*.gguf', recursive=True):   # newer Unsloth writes <out>_gguf/
    shutil.move(f, '/kaggle/working/' + os.path.basename(f))
shutil.rmtree('/kaggle/working/shipbrain_model/ckpt', ignore_errors=True)
summary = {f: json.load(open('/kaggle/working/' + f))['total'] for f in ('eval_before.json', 'eval_after.json')
           if os.path.exists('/kaggle/working/' + f)}
for f in ('cad_eval_before.json', 'cad_eval_after.json'):            # text-to-CAD on unseen parts
    try:
        summary[f] = {k: v for k, v in json.load(open('/kaggle/working/' + f))['summary'].items() if not isinstance(v, (list, dict))}
    except Exception:
        pass
for f in ('scorecard_before.json', 'scorecard_after.json'):        # realistic requests, by category
    try:
        summary[f] = json.load(open('/kaggle/working/' + f))['summary']
    except Exception:
        pass
# accept the new model only if it did not get worse (scorecard by category, tool-call evaluation)
ACCEPTED = True
if os.path.exists('/kaggle/working/scorecard_before.json') and os.path.exists('/kaggle/working/scorecard_after.json'):
    cmd = ('python training/accept_gate.py --before /kaggle/working/scorecard_before.json --after /kaggle/working/scorecard_after.json '
           '--out /kaggle/working/accept.json')
    if os.path.exists('/kaggle/working/eval_before.json') and os.path.exists('/kaggle/working/eval_after.json'):
        cmd += ' --eval-before /kaggle/working/eval_before.json --eval-after /kaggle/working/eval_after.json'
    ACCEPTED = subprocess.run(cmd, shell=True, cwd=os.getcwd()).returncode == 0
    try:
        summary['accept'] = json.load(open('/kaggle/working/accept.json'))
    except Exception:
        pass
summary['accepted'] = ACCEPTED
summary['incremental'] = INCREMENTAL
if ACCEPTED:
    # remember what this model learned + keep its adapter for the next run (private Hugging Face repo <you>/shipbrain-state)
    try:
        src_data = 'data_full/*.jsonl' if INCREMENTAL else 'data/*.jsonl'
        os.makedirs(STATE, exist_ok=True)
        if not INCREMENTAL and os.path.exists(f'{STATE}/manifest.json.gz'):
            os.remove(f'{STATE}/manifest.json.gz')              # full run: start the record again (a changed base model makes the old record wrong)
        sh(f'python training/incremental.py commit --data "{src_data}" "data/*_train.jsonl" "data/train.jsonl" --state {STATE}/manifest.json.gz --base "{BASE_ID}" --run {RUN_ID}', required=False)
        shutil.rmtree(f'{STATE}/lora', ignore_errors=True)
        shutil.copytree('/kaggle/working/shipbrain_model/lora', f'{STATE}/lora')
        sh(f'python training/incremental.py push --src {STATE}', required=False)
    except Exception as e:
        print('(could not save the model state for the next incremental run:', e, ')', flush=True)
elif not ACCEPTED:
    print('the new model was rejected by the accept gate: the saved state is NOT updated, so the next run trains on the same new data again', flush=True)
if not ACCEPTED:
    UPLOAD_MODEL = False                 # a worse model is not published anywhere; the files stay in this run's Output only
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
if token and not ACCEPTED:
    print('new model NOT uploaded to Hugging Face: the accept gate rejected it (see accept.json)', flush=True)
elif token:
    from huggingface_hub import HfApi, create_repo
    api = HfApi(token=token)
    repo = api.whoami()['name'] + '/shipbrain-gguf'
    create_repo(repo, private=True, exist_ok=True, token=token)
    for f in glob.glob('/kaggle/working/*.gguf') + ['/kaggle/working/summary.json']:
        api.upload_file(path_or_fileobj=f, path_in_repo=os.path.basename(f), repo_id=repo)
    print('uploaded to https://huggingface.co/' + repo)
# last: measure ShipBrain's model on this GPU with Simthesizer (no weights needed) -> /kaggle/working/shipbrain_serving
if os.environ.get('SB_SERVING_PROFILE', '1') != '0' and hours() < BUDGET_H - 2:
    report('measuring serving speed on this GPU (Simthesizer)')
    sh('SB_INSIDE_TRAINING=1 timeout 5400 python training/kaggle/serving_profile_kernel.py', required=False)
shutil.rmtree('/kaggle/working/src', ignore_errors=True)
report('ALL DONE', {'summary': summary})
print('ALL DONE - open the Output tab and download shipbrain-q4_k_m.gguf (and summary.json)', flush=True)
