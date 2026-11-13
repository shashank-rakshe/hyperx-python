#!/bin/bash
# ShipBrain training on Lightning AI (or any Linux PC / cloud machine with an NVIDIA GPU).
# Same code as the Kaggle run: the Kaggle kernel is downloaded and its two folders (/kaggle/working, /kaggle/input)
# are replaced by folders in your home directory. Files stay between runs (a Studio keeps its disk).
#
#   bash run_lightning.sh data     # CPU machine is enough: makes all training data   (about 1.5 h)
#   bash run_lightning.sh train    # GPU machine: trains on the data made above       (3 to 5 h)
#   bash run_lightning.sh all      # data and training in one go (needs the GPU machine the whole time)
#
# Optional settings (export before): SB_FAST=1 (shorter), SB_N_TRAIN=2500, SB_CLASS_RULES=0, SB_MODE=full|auto|new,
# HF_TOKEN (Hugging Face write token: keeps the model state for incremental runs), SB_BRANCH=<git branch>.
set -e
MODE="${1:-all}"
BRANCH="${SB_BRANCH:-claude/new-session-qpeo6g}"
BASE="$HOME/shipbrain_run"
WORK="$BASE/working"
INPUT="$BASE/input"
mkdir -p "$WORK" "$INPUT"
cd "$BASE"
curl -sL "https://raw.githubusercontent.com/shashank-rakshe/hyperx-python/$BRANCH/shipbrain/training/kaggle/kernel.py" -o kernel_kaggle.py
sed "s#/kaggle/working#$WORK#g; s#/kaggle/input#$INPUT#g" kernel_kaggle.py > kernel_local.py
if grep -qE "(^|[ '\"(=])/kaggle/(working|input)" kernel_local.py; then echo "unreplaced Kaggle path left in kernel_local.py"; grep -nE "/kaggle/(working|input)" kernel_local.py | head -3; exit 1; fi
export SB_BRANCH="$BRANCH"
case "$MODE" in
  data)  export SB_DATA_ONLY=1 ;;
  train) # use the data made before: show it to the kernel as a ready-made input
         if [ -f "$WORK/shipbrain_train_data/data_ready.flag" ]; then
           mkdir -p "$INPUT/prebuilt" && ln -sfn "$WORK/shipbrain_train_data" "$INPUT/prebuilt/shipbrain_train_data"
           echo "using the data in $WORK/shipbrain_train_data"
         else
           echo "no ready-made data found: the training run will make the data itself (run 'bash run_lightning.sh data' first to do it on a cheaper CPU machine)"
         fi ;;
  all)   ;;
  *) echo "usage: bash run_lightning.sh data|train|all"; exit 1 ;;
esac
if [ "$MODE" != "data" ]; then
  nvidia-smi -L || { echo "no NVIDIA GPU found: switch the Studio to a GPU machine first"; exit 1; }
fi
echo "starting ($MODE); log: $BASE/run_$MODE.log"
python -u kernel_local.py 2>&1 | tee "$BASE/run_$MODE.log"
echo "finished ($MODE). Results: $WORK  (model files *.gguf, summary.json)"
