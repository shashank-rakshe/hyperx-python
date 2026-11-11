#!/bin/bash
# ---------------------------------------------------------------------------
# Synthetic-bet study: train one condition (real | synthetic | mixed) in the 10-class
# DEVICE_CATALOG space, then ALWAYS evaluate best.pt on the SAME real test (delp10 test).
# Same model/epochs/seed across conditions so only the training DATA differs.
# Governed: cdai-* job, own paths, ledgered. Preemptable lane for backfill.
# ---------------------------------------------------------------------------
#SBATCH --job-name=cdai-synbet
#SBATCH --account=bedigital
#SBATCH --partition=a100_preemptable_q
#SBATCH --qos=tc_a100_preemptable_base
#SBATCH --requeue
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=4
#SBATCH --mem=48G
#SBATCH --time=00:30:00
#SBATCH --output=/projects/bedigital/cdai/logs/%x-%j.out

set -euo pipefail
module load apptainer/1.4.0

CDAI=/projects/bedigital/cdai
SIF=$CDAI/containers/ultralytics.sif
DATA=${DATA:?set DATA=<train yaml>}
NAME=${NAME:?set NAME=<condition>}
BASE=${BASE_WEIGHT:-$CDAI/code/yolo11s.pt}
EPOCHS=${EPOCHS:-100}
OUT=$CDAI/checkpoints/synbet
REALTEST=$CDAI/data/delp10.yaml        # the common real test for every condition
mkdir -p "$OUT"
export YOLO_CONFIG_DIR=$CDAI/.ultralytics; mkdir -p "$YOLO_CONFIG_DIR"

echo "== node $(hostname); condition=$NAME data=$DATA =="
nvidia-smi --query-gpu=name --format=csv,noheader
A="apptainer exec --nv -B /projects $SIF"

echo "== TRAIN ($NAME) =="
$A yolo detect train data="$DATA" model="$BASE" \
    epochs="$EPOCHS" imgsz=640 batch=16 seed=0 patience=50 \
    project="$OUT" name="$NAME" exist_ok=True plots=False verbose=True

echo "== EVAL $NAME on COMMON REAL TEST (delp10 test) =="
$A yolo detect val data="$REALTEST" model="$OUT/$NAME/weights/best.pt" split=test \
    project="$OUT" name="${NAME}_realtest" exist_ok=True plots=False

echo "== DONE condition=$NAME =="
