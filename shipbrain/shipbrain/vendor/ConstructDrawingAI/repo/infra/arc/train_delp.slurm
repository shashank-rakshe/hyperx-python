#!/bin/bash
# ---------------------------------------------------------------------------
# ARC job #1 — train a detector on REAL DELP data, eval on the held-out DELP test.
# The real-trained counterpoint to our synthetic-only baseline (0.0% mAP on DELP):
# does training on ANY real data produce a working real-drawing detector? (SkeySpot
# published SOTA on this data is ~82.5% mAP.)  Research lane (DELP is CC BY 4.0).
#
# GOVERNANCE (shared `bedigital` account): namespaced job (cdai-*), own paths only,
# logged in /projects/bedigital/cdai/jobs.ledger. Never touches other agents' jobs.
# ---------------------------------------------------------------------------
#SBATCH --job-name=cdai-delp-yolo
#SBATCH --account=bedigital
#SBATCH --partition=a100_normal_q
#SBATCH --qos=tc_a100_normal_short
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=00:30:00
# ^ short walltime on purpose: DELP is tiny (~10 min on one A100), and a short limit
#   backfills into idle GPUs immediately instead of waiting for a full-node reservation.
#SBATCH --output=/projects/bedigital/cdai/logs/%x-%j.out

set -euo pipefail
module load apptainer/1.4.0

CDAI=/projects/bedigital/cdai
SIF=$CDAI/containers/ultralytics.sif
DATA=$CDAI/data/delp_yolo/data.yaml
# Parametrized so one script serves the baseline + scale-up runs (override via --export).
BASE=${BASE_WEIGHT:-$CDAI/code/yolo11s.pt}
EPOCHS=${EPOCHS:-100}
NAME=${RUN_NAME:-run}
SEED=${SEED:-0}
OUT=$CDAI/checkpoints/delp_yolo
mkdir -p "$OUT"

# ultralytics needs a writable config/cache dir (container HOME may be read-only).
export YOLO_CONFIG_DIR=$CDAI/.ultralytics
mkdir -p "$YOLO_CONFIG_DIR"

echo "== node: $(hostname) =="
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader

# Bind /projects explicitly in case it is not an auto-mount inside the container.
APPTAINER="apptainer exec --nv -B /projects $SIF"

echo "== TRAIN on real DELP (model=$BASE epochs=$EPOCHS name=$NAME) =="
$APPTAINER yolo detect train \
    data="$DATA" model="$BASE" \
    epochs="$EPOCHS" imgsz=640 batch=16 seed="$SEED" patience=60 \
    close_mosaic=10 mixup=0.1 copy_paste=0.1 degrees=5 translate=0.1 scale=0.3 \
    project="$OUT" name="$NAME" exist_ok=True plots=True verbose=True

echo "== EVAL best.pt on held-out TEST split =="
$APPTAINER yolo detect val \
    data="$DATA" model="$OUT/$NAME/weights/best.pt" split=test \
    project="$OUT" name="${NAME}_test" exist_ok=True plots=True

echo "== DONE =="
