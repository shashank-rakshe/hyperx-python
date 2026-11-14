---
title: Serving systems
---

# Serving systems

A `System` owns request lifecycle. It turns a request DAG into graph nodes,
feeds LLM work to its scheduler, launches iterations on its runner, and
assembles results. Systems compose into a tree, and a parent sees only requests
going in and completion events coming out.

## Single instance

`single_instance` is one serving stack: one model, one runner, one scheduler.
Seeding a request creates a release node and an arrival/completion pair per
sub-request:

```text
release ──> arrival[i] ──> complete[i] ──> arrival[j]
            (i initial)                    (j in next of i)
```

When `arrival[i]` runs, it waits the sub-request's `interval` and splices work
in front of its completion: a tool call becomes one logical node lasting its
`duration`, and an LLM call is enqueued into the scheduler.

Iterations form a self-sustaining chain that exists only while there is work:

```text
schedule ──> runner iteration ──> batch complete ──> schedule ...
                                        └──> complete[k] per finished sub-request
```

At most one iteration is in flight. The scheduler never sees tool calls.

## Composition

| `kind` | Models |
|---|---|
| `multi_instance` | Independent instances behind a router that places each whole request at its simulated arrival. |
| `moe_ep_multi_instance` | Expert parallelism with data-parallel attention: one scheduler per rank, one shared EP runner, and iterations that run as cluster-wide waves. |
| `pd_disaggregation` | Prefill and decode pools. A request's prefill child produces the first token, a KV transfer between workers gates the decode child, and both results merge into one. Pools are picked round-robin, and only requests with a single LLM call are supported. |

`multi_instance` and `pd_disaggregation` compose child systems through seeding
and sinks. A new topology should compose the same way before duplicating
lifecycle code.

Source of truth:
[`architectures/systems.md`](https://github.com/casys-kaist/Simthesizer/blob/main/architectures/systems.md).
