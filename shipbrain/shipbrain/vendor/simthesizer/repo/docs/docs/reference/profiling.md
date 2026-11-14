---
title: Profiling
---

# Profiling

`scripts/profile.py` runs synthetic batches through vLLM's model runner and
times selected components with Triton Proton's CUPTI backend. Its output is the
JSONL profile that the [`table_lookup`](../simulator/cost-models.md) compute
simulator reads.

```bash
CUDA_VISIBLE_DEVICES=0 uv run --group vllm scripts/profile.py \
  examples/profiles/llama3_1_8b.toml --output output/llama3_1_8b.jsonl
```

`--dry-run` expands the batches without loading vLLM. `--model` selects a local
model directory, which also avoids fetching a gated Hugging Face config.
`--variant` and `--limit` restrict a run. The output path must not already
exist.

## Receipt

A receipt such as `examples/profiles/llama3_1_8b.toml` declares:

- `engine`: native `vllm.LLM` arguments. Defaults use dummy weights, eager
  execution, and no prefix caching.
- `components`: output names mapped to glob patterns over module paths.
- `batches`: request groups whose `count`, `query`, and `context` accept
  integers or lists. Lists form a Cartesian product of exact batch shapes.
- `measure` (optional): warmup seconds, samples, and iterations per sample;
  defaults 1.0, 5, and 3.
- `repeat` (optional): a block to repeat for a model's depth, so one decoder
  layer can stand in for the full stack.
- `variants` (optional): named engine overrides for TP, dtype, quantization, or
  shape experiments.

## What is measured

Each sample reports the sum of a component's descendant GPU kernel durations
divided by its invocation count. The estimate is the median of those sample
means. This measures eager GPU work, not CPU dispatch gaps or CUDA graph replay.

Hardware, effective model configuration, and software versions are recorded
with the measurements. Profiles live at `examples/data/<device>/<model>.jsonl`.

Source of truth:
[`architectures/profiling.md`](https://github.com/casys-kaist/Simthesizer/blob/main/architectures/profiling.md).
