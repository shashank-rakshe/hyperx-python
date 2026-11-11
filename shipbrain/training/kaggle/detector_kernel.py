"""
Train ConstructDrawingAI's electrical symbol detector (its own code, unchanged) on a FREE Kaggle GPU - a separate
notebook from the language-model run, so it does not take that run's time.

Kaggle: New Notebook -> Accelerator GPU T4 x2 (or P100) -> Internet on -> paste this file -> Run all (about 1-2 hours).
Then download /kaggle/working/shipbrain_cdai_electrical.pt and put it on your PC as
    ~/.shipbrain/cdai/electrical.pt          (or set SHIPBRAIN_CDAI_WEIGHTS to its path)
ShipBrain's drawing_detect tool then reads electrical drawing pictures: symbols -> CIR -> takeoff / Q&A.

What it does: its synthetic engine draws N electrical drawing sets (plan + single-line + schedule, scan damage
included) with exact boxes -> its exporter tiles them into a YOLO dataset -> its trainer fine-tunes a COCO-pretrained
YOLO11 model -> the best weights are copied out. Licences: ConstructDrawingAI PolyForm Noncommercial, Ultralytics
AGPL-3.0 - fine for ShipBrain (declared open and non-commercial).
"""
import glob, os, shutil, subprocess

N_SETS = 1200            # synthetic drawing sets
EPOCHS = 80
ARCH = 'yolo11s.pt'      # small: good on a T4; 'yolo11m.pt' for more accuracy (slower)
BRANCH = 'claude/new-session-qpeo6g'
REPO = 'https://github.com/shashank-rakshe/hyperx-python.git'


def sh(cmd):
    print('$', cmd, flush=True)
    subprocess.run(cmd, shell=True, check=True)


os.chdir('/kaggle/working')
shutil.rmtree('src', ignore_errors=True)
sh(f'git clone -b {BRANCH} --depth 1 {REPO} src')
root = '/kaggle/working/src/shipbrain/shipbrain/vendor/ConstructDrawingAI/repo'
sh('pip -q install ultralytics pydantic msgpack pyyaml omegaconf hydra-core pillow numpy')
os.chdir(root)
sh(f'python -m synthetic.generate --type electrical --n {N_SETS} --degradation-range 0..3 --out datasets/synthetic/electrical_pilot --seed 0 --style-seed 0')
sh('python -m perception train-detector --profile local_debug -o data.limit_samples=null -o data.include_degraded=true '
   f'-o train.epochs={EPOCHS} -o train.batch=16 -o model.arch={ARCH} -o train.patience=20')
best = sorted(glob.glob('outputs/perception/detector/**/weights/best.pt', recursive=True), key=os.path.getmtime)
if not best:
    raise SystemExit('no weights produced')
shutil.copy(best[-1], '/kaggle/working/shipbrain_cdai_electrical.pt')
sh('python -m perception eval-detector --profile local_debug --weights /kaggle/working/shipbrain_cdai_electrical.pt || true')
print('done: /kaggle/working/shipbrain_cdai_electrical.pt')
