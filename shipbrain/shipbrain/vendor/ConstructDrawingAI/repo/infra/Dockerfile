# syntax=docker/dockerfile:1
#
# Base image for the ConstructDrawingAI platform. Build from the REPO ROOT:
#   docker build -f infra/Dockerfile -t constructdrawing-ai .
#
# This image serves the FastAPI backend by default. It is also the basis for the
# Apptainer/Singularity .sif used on the ARC cluster (Build Playbook step 2.2):
#   apptainer build cdai.sif docker-daemon://constructdrawing-ai:latest
#
# Heavy, phase-specific dependencies (torch, CUDA, ifcopenshell, blender, ...) are
# layered on per-phase; this base stays lean.

FROM python:3.12-slim AS base

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1

# Minimal system deps. CAD/PDF/IFC system libraries are added when L0 ingestion lands.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*

# uv (fast, reproducible installs).
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

# Install dependencies first (better layer caching), then the source.
COPY pyproject.toml uv.lock README.md ./
COPY cir ./cir
COPY ingest ./ingest
COPY perception ./perception
COPY grounding ./grounding
COPY engines ./engines
COPY agent ./agent
COPY synthetic ./synthetic
COPY eval ./eval
COPY backend ./backend
COPY datasets ./datasets

RUN uv sync --extra backend --frozen

EXPOSE 8000
CMD ["uv", "run", "uvicorn", "backend.app:app", "--host", "0.0.0.0", "--port", "8000"]
