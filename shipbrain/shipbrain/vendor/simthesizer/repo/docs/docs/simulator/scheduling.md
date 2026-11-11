---
title: Scheduling
---

# Scheduling

A `Scheduler` owns the ready LLM sub-requests of one memory domain: which run in
the next iteration, how many tokens each processes, and what KV each holds. It
is the only component that tracks token progress. Runners see only the batch
shape. A `Router` owns whole-request placement across instances.

## Chunked prefill

`chunked_prefill` models vLLM-style continuous batching with chunked prefill.

- Requests are served first come, first served. An iteration admits them in
  order until `max_batch`, `max_num_batched_tokens`, or memory runs out.
- Usable memory is `device_mem × device_mem_utilization`. It holds weights,
  prefix-cache blocks, block-rounded KV, and per-request state such as Mamba
  SSM state. A request is admitted only if its footprint after the iteration
  fits.
- Requests that hold KV but no longer fit are preempted. Their KV is dropped
  and recomputed later.
- A token is emitted when an iteration brings KV up to the known tokens.

## Prefix cache

Enabled with `enable_prefix_caching`.

- One cache per scheduler, never shared across schedulers: separate instances,
  `moe_ep_multi_instance` ranks, and disaggregated pools each keep their own.
- Block-granular and hash-chained over token IDs, so it needs token traces in
  the workload. A hit is the longest chain of full blocks.
- Unreferenced blocks stay in LRU order and are evicted only under memory
  pressure. Cached blocks count against device memory.
- After each iteration, a request publishes its newly completed full blocks,
  so prefixes become shareable while it still runs.

Memory is modeled by allocating and reclaiming real blocks, not with capacity
or hit-rate factors.

## Routing

A router picks one destination from per-instance load snapshots. It never
splits a request or touches scheduler state.

| `kind` | Policy |
|---|---|
| `round_robin` | Ignores load. |
| `moe_load_balancing` | Lowest queued plus running tokens, then requests, rotating ties. |

Source of truth:
[`architectures/scheduling.md`](https://github.com/casys-kaist/Simthesizer/blob/main/architectures/scheduling.md).
