# infra

Dockerfiles, SLURM/Apptainer job templates, and deployment configs.

## Contents

| File | Purpose |
|---|---|
| `Dockerfile` | Lean base image; serves the FastAPI backend; basis for the ARC `.sif`. |
| `docker-compose.yml` | Local dev stack (backend API today; model servers + webapp later). |
| `slurm/train.slurm` | H200 multi-seed training template for VT ARC (containerized, resumable). |

## Local

```bash
# From the repo root:
docker build -f infra/Dockerfile -t constructdrawing-ai .
docker compose -f infra/docker-compose.yml up --build      # http://localhost:8000/docs
```

## Cluster (VT ARC TinkerCliffs, H200)

1. Build the reproducible container from the Dockerfile, then convert to Apptainer:
   ```bash
   apptainer build cdai.sif docker-daemon://constructdrawing-ai:latest
   ```
2. Pull training data/weights with **DVC** (never git) on the login node:
   `git clone … && dvc pull`.
3. Submit a multi-seed job **array** (mean + CI for the paper); use the preemptable
   queue for long self-supervised/synthetic pretraining:
   ```bash
   sbatch --array=0-2 infra/slurm/train.slurm h200-full perception.train
   squeue -u "$USER"      # monitor
   ```
4. Compute nodes run W&B **offline**; `wandb sync wandb/offline-*` from the login node.

## Golden rules

- **ARC is for training; cloud is for serving.** Don't host a live service on a shared
  HPC cluster.
- **Code travels by git; data and model weights travel by DVC.** Never commit large
  artifacts.
- **Push only commercial-lane weights** to the deployable-models remote; keep
  research-lane weights in a separate, clearly-labeled location.
