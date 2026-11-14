"""
ShipBrain DATA notebook: downloads every outside data source once, on Kaggle (Kaggle has internet; the build session
does not). No GPU needed.

1. Kaggle -> Create -> New Notebook. Right panel: Accelerator None, Internet ON (needs a phone-verified Kaggle account).
2. Paste this whole file into the first cell -> Save Version -> Save & Run All (about 30-90 minutes).
3. When it has finished: open the notebook -> Output -> you see shipbrain_data/ (manifest.json says what came).
4. In the TRAINING notebook (training/kaggle/kernel.py): right panel -> Add Input -> Your Work -> Notebooks -> pick this
   data notebook. The training run finds shipbrain_data/ by itself and uses it instead of downloading.
   (Or: Output -> "New Dataset" to make it a Kaggle dataset, then Add Input -> Your Datasets.)
Keep this notebook and its output PRIVATE (the default): the class rule books are copyright of each society.
Rule books that need a login (some ClassNK, LR, KR): download them on your PC into folders <society>/, upload them as
a private Kaggle dataset whose name contains "rules", and attach it to the training notebook too.
"""
import os, shutil, subprocess

BRANCH = 'claude/new-session-qpeo6g'
REPO = 'https://github.com/shashank-rakshe/hyperx-python.git'
OUT = '/kaggle/working/shipbrain_data'


def sh(cmd, check=True):
    print('$', cmd, flush=True)
    return subprocess.run(cmd, shell=True, check=check).returncode == 0


os.chdir('/kaggle/working')
shutil.rmtree('src', ignore_errors=True)
sh(f'git clone -b {BRANCH} --depth 1 {REPO} src')
os.chdir('/kaggle/working/src/shipbrain')
sh('pip -q install numpy pillow pypdfium2 gdown', check=False)
sh(f'python training/fetch_data.py --out {OUT}', check=False)
shutil.rmtree('/kaggle/working/src', ignore_errors=True)        # only the data stays in the output
sh(f'du -sh {OUT}/* ; cat {OUT}/manifest.json', check=False)
