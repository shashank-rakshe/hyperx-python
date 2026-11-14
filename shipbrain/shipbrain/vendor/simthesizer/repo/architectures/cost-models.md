# Cost Model Architecture

## Purpose

Simulators price graph nodes. A compute simulator returns the latency of one
layer for one batch. A network simulator returns the duration of point-to-point
transfers under contention. Each instance belongs to one owner, a runner or a
disaggregated system, which initializes it.

## Table Lookup Compute

`perf_dir` names a `.jsonl` profile for one model and machine. The loader requires
format version 1, a complete run, and a matching TP degree. `profile_variant`
selects a variant when several exist. Rank 0 supplies the timings.

A `components` map connects model layer names to lists of profile component
names; omitted names match directly. Multiple components or instances combine
by invocation count within each sample, then take the median. Microseconds
convert to seconds at this boundary. An uncalled component contributes no sample;
a called component with zero GPU work contributes zero latency.

Tables are built on first use, when the model's layer type determines how exact
request shapes project into lookup keys:

| Layer | `key_0` | `key_1` |
|---|---|---|
| token-wise (embedding, norm, GEMM, RoPE, activation) | 0 | total query tokens |
| attention, Mamba | Σ `kv_len` | Σ `q_len · (q_len/2 + kv_len)` |
| LM head, sampler | 0 | sampled rows |

Samples that project to the same keys average. Interpolation is piecewise linear,
clamped below the smallest sample and extrapolated above the largest. Attention
holds compute/memory constant across nonzero KV rows; zero-KV prefill uses the
raw compute axis. Multi-token batches exclude decode-only samples from inner
interpolation because their kernels can differ.

One-token attention samples also build a table indexed by batch size, maximum KV,
and total KV. Its interpolation preserves mean/maximum KV. Without such samples,
attention uses the two-key table. Prefill uses compute/KV keys; kernel tile
metadata is not part of the current profile format.

Optional `cudagraph_capture_sizes` pads token-wise dense lookup to the next
captured size. Attention, LM head, sampler, and measured shapes remain unpadded.
Batches beyond the largest captured size remain unpadded. Missing components
fail the run. Forced MoE routing is not yet supported by this loader.

## Profiling

[`scripts/profile.py`](profiling.md) emits exact-shape JSONL measurements under
`examples/data/<device>/`. Each scenario names its profile explicitly; model and
hardware must match. The simulator does not load CSV profiles.

## Flow Network

- Owners register devices and directed links (bandwidth, latency) during
  initialization. Multi-hop routes prefer the widest bottleneck, then the
  lowest latency, then the fewest hops, and are cached until the topology
  changes.
- A flow transmits at its rate, then waits its route's total latency.
- Each link divides its bandwidth equally among its active flows, and a flow
  runs at its tightest link's share. Bandwidth a flow cannot use is not
  redistributed.
- The simulator keeps its own clock, advanced on every poll, and answers each
  pending poll with the delay to its next flow event. This revisits rates when
  another flow releases bandwidth.
- Every owner has its own instance, so flows of different owners never contend.

## Evolution Rules

- Price compute from profiles; extend the profile rather than adding a formula
  fallback.
- `link_bw` is measured effective bandwidth, not the theoretical peak.
- A new cost model is a new simulator `kind`; graph nodes stay unchanged.
