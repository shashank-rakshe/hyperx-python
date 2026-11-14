---
title: Event engine
---

# Event engine

The engine owns virtual time and execution order. It knows three node kinds and
nothing about requests, batches, or models.

## Node kinds

| Node | Holds | Latency from |
|---|---|---|
| Compute | One layer and one batch of per-request `(q_len, kv_len, lm_head_len)` | Its compute simulator |
| Network | One point-to-point transfer `(src, dst, bytes)` | Its network simulator, polled until done |
| Logical | An opaque payload for one owning handler | The handler, which may also mutate the graph |

Payloads are private to their owner. The engine never inspects them, so new
behavior needs no engine change.

## Execution

A node becomes ready when every predecessor has completed. It starts at the
later of its release time and its last predecessor's finish. Ready nodes run in
`(start time, node ID)` order. IDs increase with creation, so ties resolve by
creation order and runs are deterministic.

A network poll answers either _complete_ or _pending with a delay_. A pending
node requeues itself after that delay, so concurrent transfers can change each
other's rates.

The run ends when no node is ready. A node left in the graph means a cycle or an
orphan, and the run fails.

## Graph mutation

Only a running logical handler mutates the graph, in two ways:

- add nodes beneath the running node;
- detach the running node's outgoing edges and reattach those children beneath
  newly added work.

Detach and reattach **splice** dynamic work into a pre-seeded DAG. A static
dependency survives, but its target now also waits for work that did not exist
when it was seeded. This is how scheduling decisions, iterations, and tool calls
enter a request's timeline.

## Observation

After every event at a timestamp has drained, the engine can call a read-only
observer. Components expose their own state as JSON, and the CLI writes these
snapshots with `--output-engine-trace`. Observation adds no nodes and no cost.

Source of truth:
[`architectures/engine.md`](https://github.com/casys-kaist/Simthesizer/blob/main/architectures/engine.md),
[`architectures/observability.md`](https://github.com/casys-kaist/Simthesizer/blob/main/architectures/observability.md).
