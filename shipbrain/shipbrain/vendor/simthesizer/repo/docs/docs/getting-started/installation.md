---
title: Installation
---

# Installation

| Task | Needs |
|---|---|
| Simulation | Rust stable |
| Profiling and baselines | [uv](https://docs.astral.sh/uv/), Linux with an NVIDIA GPU, and a CUDA toolkit |

## Clone and build

```bash
git clone https://github.com/casys-kaist/Simthesizer.git
cd Simthesizer
cargo build --release
```

This builds the `simthesizer` binary, which is all you need to run every
bundled scenario under `examples/`.

## Python environment

Profiling, baseline replay, comparison, and plotting are Python scripts. They
use one project environment: `.python-version` sets the Python version, and
`pyproject.toml` with `uv.lock` set the dependencies.

```bash
uv sync --locked                 # analysis: compare.py, draw.py
uv sync --locked --group vllm    # profiling and baseline replay on a GPU
```

vLLM ships Linux wheels only. Profiling also needs a CUDA toolkit; the devenv
`vllm` profile below supplies one.

## devenv (optional)

The repository also ships a [devenv](https://devenv.sh/) environment that
supplies Rust, Python, and uv:

```bash
devenv shell                    # simulation and analysis
devenv --profile vllm shell     # adds vLLM, CUDA build tools, and driver libraries
```
