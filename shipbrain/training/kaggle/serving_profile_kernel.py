"""
Measure ShipBrain's model on a Kaggle GPU with Simthesizer's own profiler, so `serving_sim` can predict how fast
ShipBrain answers MANY users on that card. Separate notebook; needs no model weights (dummy weights, config only).

The TRAINING notebook (kernel.py) already runs this at its end on its own GPU (SB_SERVING_PROFILE=0 to skip);
this file is only for measuring on its own:
Kaggle: New Notebook -> Accelerator "GPU T4 x2" (not P100: too old for vLLM) -> Internet ON -> paste this file ->
Save & Run All (about 20-40 min). Output: shipbrain_serving/ with
    profile.jsonl          the measured GPU time of every model component for 29 batch shapes
    simthesizer.toml       the matching Simthesizer set-up (T4 + ShipBrain's model)
    receipt.json           which GPU / vLLM / model were measured
Then on your PC (or ask the assistant to fetch it):  python -c "from shipbrain import serving; serving.add_profile('shipbrain_serving')"

Uses Simthesizer's pinned toolchain exactly: Python 3.14 + vLLM 0.31 through `uv` (installed here). If vLLM refuses
the GPU (it needs compute capability 7.0+), the log says so and nothing else is changed.
"""
import glob, json, os, shutil, subprocess

BRANCH = 'claude/new-session-qpeo6g'
REPO = 'https://github.com/shashank-rakshe/hyperx-python.git'
OUT = '/kaggle/working/shipbrain_serving'
GPU_NAME = 'T4'


def sh(cmd, check=True):
    print('$', cmd, flush=True)
    return subprocess.run(cmd, shell=True, check=check).returncode == 0


INSIDE = os.environ.get('SB_INSIDE_TRAINING') == '1'     # called by the training notebook: use its checkout, keep it
if INSIDE:
    base = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))   # .../shipbrain
else:
    os.chdir('/kaggle/working')
    shutil.rmtree('src', ignore_errors=True)
    sh(f'git clone -b {BRANCH} --depth 1 {REPO} src')
    base = '/kaggle/working/src/shipbrain'
root = f'{base}/shipbrain/vendor/simthesizer/repo'
receipt = f'{base}/training/serving/qwen3_4b.toml'
sh('nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv', check=False)
sh('pip -q install uv')
os.makedirs(OUT, exist_ok=True)
os.chdir(root)
ok = sh(f'uv run --python 3.14 --group vllm scripts/profile.py {receipt} --output {OUT}/profile.jsonl', check=False)
if not ok or not os.path.exists(f'{OUT}/profile.jsonl'):
    raise SystemExit('profiling did not finish - see the log above (GPU type / vLLM version)')
mem = subprocess.run('nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits', shell=True,
                     capture_output=True, text=True).stdout.splitlines()[0].split(',')
gpu, mib = mem[0].strip(), int(mem[1])
scen = open(glob.glob('examples/scenarios/*/simthesizer.toml')[0]).read()
import re
scen = re.sub(r'perf_dir = ".*"', 'perf_dir = "profile.jsonl"', scen)
scen = re.sub(r'device_mem = \d+', f'device_mem = {mib * 1024 * 1024}', scen)
model = {'hidden_size': 2560, 'intermediate_size': 9728, 'max_position_embeddings': 40960,
         'num_attention_heads': 20,          # 2560 / 20 = 128 = Qwen3-4B's head size: KV cache per token exact
         'num_hidden_layers': 36, 'num_key_value_heads': 8, 'vocab_size': 151936}
scen = re.sub(r'\[system\.model\][^\[]*', '[system.model]\nkind = "llama3_1"\n' + ''.join(f'{k} = {v}\n' for k, v in model.items()) + '\n', scen)
open(f'{OUT}/simthesizer.toml', 'w').write(scen)
json.dump({'gpu': gpu, 'memory_MiB': mib, 'model': 'Qwen3-4B text layout (ShipBrain base Qwen3-VL-4B, language part)',
           'note': 'attention heads given as 20 x 128 (Qwen3-4B: 32 query heads x 128, 8 KV heads) so the KV cache per token is exact; '
                   'q/k norms not timed separately; vision encoder not included'}, open(f'{OUT}/receipt.json', 'w'), indent=1)
sh(f'ls -la {OUT}; head -c 600 {OUT}/profile.jsonl', check=False)
if not INSIDE:
    shutil.rmtree('/kaggle/working/src', ignore_errors=True)
