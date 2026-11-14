---
title: Quickstart
---

# Quickstart

A scenario directory under `examples/scenarios/` pairs a simulator config
(`simthesizer.toml`) with the matching vLLM engine arguments (`baseline.toml`).
Scenario names follow `<count>x<device>--<model>--<workload>`.

## 1. Simulate

```bash
cargo run --release -- \
  --config examples/scenarios/1xrtx-pro-6000--llama3_1_8b--realistic/simthesizer.toml \
  --workload examples/workloads/realistic.jsonl \
  --output-jsonl output/sim.jsonl
```

No GPU is needed. Each output row repeats the request DAG and adds a
`token_latency` array to every LLM call: time to first token, then inter-token
latencies. See [Workload format](../reference/workload-format.md).

Add `--output-engine-trace output/trace.jsonl` to also record component state
over simulated time. The trace file must not already exist.

## 2. Profile

The simulator prices compute from latency tables measured with vLLM on the
target GPU. To profile a model on new hardware:

```bash
CUDA_VISIBLE_DEVICES=0 uv run --group vllm scripts/profile.py \
  examples/profiles/llama3_1_8b.toml --output output/llama3_1_8b.jsonl
```

The receipt (`examples/profiles/*.toml`) declares engine arguments, the
components to time, and the batch shapes to sweep. The output path must not
already exist. Point `perf_dir` in a scenario's `simthesizer.toml` at the new
profile to use it. See [Profiling](../reference/profiling.md).

## 3. Validate

Replay the same workload on real vLLM, then compare serving metrics and plot:

```bash
CUDA_VISIBLE_DEVICES=0 uv run --group vllm scripts/baseline.py \
  --config examples/scenarios/1xrtx-pro-6000--llama3_1_8b--realistic/baseline.toml \
  --workload examples/workloads/realistic.jsonl --output-jsonl output/real.jsonl
uv run scripts/compare.py real=output/real.jsonl sim=output/sim.jsonl
uv run scripts/draw.py --output output/plot.png real=output/real.jsonl sim=output/sim.jsonl
```

The first file is the reference; any number of candidates can follow. See
[Validation](../reference/validation.md).
