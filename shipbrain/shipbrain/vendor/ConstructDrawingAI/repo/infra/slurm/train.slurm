#!/bin/bash
# ---------------------------------------------------------------------------
# SLURM template for full training runs on VT ARC TinkerCliffs (H200, 8/node).
#
# This is a TEMPLATE (Build Playbook step 2.2 generates the production versions
# and a Python launcher). Submit a multi-seed job array so we get mean + CI:
#   sbatch --array=0-2 infra/slurm/train.slurm h200-full perception.train
#
# Conventions baked in: containerized (Apptainer) for reproducibility, checkpoint
# every ~30 min to scratch, auto-resume on requeue (handle preemption), and W&B in
# offline mode on compute nodes (synced from the login node afterward).
# ---------------------------------------------------------------------------
#SBATCH --job-name=cdai-train
#SBATCH --partition=h200_normal_q        # use the preemptable queue for long pretrain
#SBATCH --account=REPLACE_ME             # your ARC allocation
#SBATCH --nodes=1
#SBATCH --gres=gpu:8                      # 8x H200 (141 GB) per node
#SBATCH --cpus-per-task=64
#SBATCH --mem=0                           # all memory on the node
#SBATCH --time=24:00:00
#SBATCH --requeue                         # allow preemption + auto-requeue
#SBATCH --signal=B:USR1@120               # warn the job before preemption to checkpoint
#SBATCH --output=logs/%x-%A_%a.out

set -euo pipefail

CONFIG="${1:?usage: train.slurm <config> <entrypoint>}"   # e.g. h200-full
ENTRYPOINT="${2:?usage: train.slurm <config> <entrypoint>}"  # e.g. perception.train
SEED="${SLURM_ARRAY_TASK_ID:-0}"

# Reproducible container built from infra/Dockerfile.
SIF="${SIF:-$HOME/containers/cdai.sif}"

# W&B offline on compute nodes; `wandb sync` on the login node uploads later.
export WANDB_MODE=offline
export WANDB_DIR="$SLURM_SUBMIT_DIR/wandb"

# Data + checkpoints live on scratch, pulled via DVC before submission.
SCRATCH="${SCRATCH:-/scratch/$USER}/cdai"
CKPT_DIR="$SCRATCH/checkpoints/${ENTRYPOINT}-${CONFIG}-seed${SEED}"
mkdir -p "$CKPT_DIR" logs

echo "Running ${ENTRYPOINT} (config=${CONFIG}, seed=${SEED}) on $(hostname)"

# FSDP across the node's GPUs. --resume picks up the latest checkpoint on requeue.
srun apptainer exec --nv "$SIF" \
    uv run torchrun --standalone --nproc_per_node=8 \
        -m "$ENTRYPOINT" \
        --config "$CONFIG" \
        --seed "$SEED" \
        --checkpoint-dir "$CKPT_DIR" \
        --checkpoint-every-min 30 \
        --resume
