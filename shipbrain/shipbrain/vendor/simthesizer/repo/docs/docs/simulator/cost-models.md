---
title: Cost models
---

# Cost models

Simulators price graph nodes. A compute simulator returns the latency of one
layer for one batch. A network simulator returns the duration of point-to-point
transfers under contention. Each instance belongs to one owner, a runner or a
disaggregated system.

## Table lookup compute

`table_lookup` reads a JSONL profile measured for one model on one machine
(see [Profiling](../reference/profiling.md)). A `components` map in the
scenario joins model layer names to profile component names.

Request shapes project into lookup keys by layer type:

| Layer | `key_0` | `key_1` |
|---|---|---|
| Token-wise (embedding, norm, GEMM, RoPE, activation) | 0 | Total query tokens |
| Attention, Mamba | Σ `kv_len` | Σ `q_len · (q_len/2 + kv_len)` |
| LM head, sampler | 0 | Sampled rows |
| MoE | Total tokens | Locally activated experts |

Interpolation is piecewise linear, clamped below the smallest sample and
extrapolated above the largest. Optional `cudagraph_capture_sizes` pads
token-wise lookups to the next captured size. A missing component fails the run
rather than falling back to a formula.

## Flow network

`flow` models transfers over a registered topology of devices and directed
links.

- Multi-hop routes prefer the widest bottleneck, then the lowest latency, then
  the fewest hops.
- Each link divides its bandwidth equally among its active flows, and a flow
  runs at its tightest link's share.
- The simulator answers each pending poll with the delay to its next flow
  event, so rates are revisited when another flow releases bandwidth.

Set `link_bw` to measured effective bandwidth, not the theoretical peak.

Source of truth:
[`architectures/cost-models.md`](https://github.com/casys-kaist/Simthesizer/blob/main/architectures/cost-models.md).
