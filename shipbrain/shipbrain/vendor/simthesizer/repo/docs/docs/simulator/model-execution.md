---
title: Model execution
---

# Model execution

A `Model` describes what one iteration computes. A `ModelRunner` decides how it
executes across devices. Together they expand one scheduled batch into compute
and network nodes.

## Model

Initialized with a parallel strategy, a model exposes a layer plan that is
already sharded for that strategy: pre-block layers, one representative block
with its repeat count, and post-block layers.

- Layers are named descriptors with shape metadata: embedding, layer norm,
  GEMM, RoPE, attention, Mamba, activation, sampler, MoE, and an all-reduce
  marker for TP synchronization.
- A model reports weight bytes per device, KV bytes per token, and per-request
  state bytes. The scheduler sizes memory from these.
- Built-ins: `llama3_1`, `qwen3_moe`, `nemotron_h` (hybrid Mamba, attention,
  and MoE).

## Model runner

A runner owns exactly one parallelism axis, the device topology it registers
with its network simulator, and its compute and network simulators.

| `kind` | Parallelism | Collectives |
|---|---|---|
| `ring` | Tensor parallel | Each all-reduce marker becomes a ring all-reduce: `2(tp − 1)` steps of `tp` concurrent transfers, separated by barriers. |
| `moe_ep` | Expert parallel | Each MoE layer becomes routing, an all-to-all dispatch, one compute node per rank, a barrier, and an all-to-all combine. |

Collectives are point-to-point transfers joined by barriers, so the network
model sees real contention.

## Block fast-forward

A runner simulates the representative block once, then one logical node adds
`(count − 1)` times that block's measured latency. Graph size per iteration
scales with block width rather than model depth.

## MoE routing

Expert choice is sampled from a seeded generator. Each rank's compute is priced
by its local token count and its locally activated experts. Dispatch sends one
payload per token to each distinct remote owner; combine reverses it.

Source of truth:
[`architectures/execution.md`](https://github.com/casys-kaist/Simthesizer/blob/main/architectures/execution.md).
