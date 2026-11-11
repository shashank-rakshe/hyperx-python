---
title: Validation
---

# Validation

Accuracy is measured against real runs. The simulator and a vLLM replay emit
the same result JSONL, so they can be compared metric by metric.

## Baseline replay

`scripts/baseline.py` drives vLLM with the scenario's `baseline.toml`. It
replays each request's token IDs at its arrival time, with EOS ignored, and
records client-visible per-token latency. Its GPU and serving settings must
match the profile.

```bash
CUDA_VISIBLE_DEVICES=0 uv run --group vllm scripts/baseline.py \
  --config examples/scenarios/1xrtx-pro-6000--llama3_1_8b--realistic/baseline.toml \
  --workload examples/workloads/realistic.jsonl --output-jsonl output/real.jsonl
```

The replay supports requests made of one LLM call with `input_token_ids` and
no interval, and refuses to overwrite existing output. Analysis supports full
DAGs, including parallel branches, joins, intervals, and tools.

## Compare and plot

```bash
uv run scripts/compare.py real=output/real.jsonl sim=output/sim.jsonl
uv run scripts/draw.py --output output/plot.png real=output/real.jsonl sim=output/sim.jsonl
uv run scripts/draw.py real=output/real.jsonl sim=output/sim.jsonl \
  --view scatter --metrics ttft tpot e2e --output output/scatter.pdf
```

The first file is the reference. `compare.py` reports the mean and percentiles
(default 50, 95, 99) with signed relative error. Paired samples also report MAE,
bias, MAPE, and WAPE. `draw.py` draws latency CDFs, paired scatter plots, and
throughput or cumulative-output time series.

## Metrics

For an LLM call with latency array `L` and `N = len(L)`:

| Metric | Definition |
|---|---|
| `ttft` | `L[0]`: enqueue to first token, including queueing |
| `tpot` | `sum(L[1:]) / (N − 1)` |
| `itl` | Each entry of `L[1:]` |
| `e2e` | `sum(L)` |
| `normalized_e2e` | `sum(L) / N` |
| `request_e2e` | Last DAG node completion minus request arrival |
| `makespan` | Last DAG completion minus first request arrival |
| `output_throughput` | All LLM output tokens divided by makespan |
| `request_throughput` | Completed request DAGs divided by makespan |

All compared runs must contain the same requests, arrivals, DAG edges,
intervals, token counts, and tool durations.

Source of truth:
[`architectures/validation.md`](https://github.com/casys-kaist/Simthesizer/blob/main/architectures/validation.md).
