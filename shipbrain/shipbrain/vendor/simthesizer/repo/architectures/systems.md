# Serving System Architecture

## Purpose

A `System` owns request lifecycle. It turns a request DAG into graph nodes,
feeds LLM work to its scheduler, launches iterations on its runner, and
assembles results. Systems compose into a tree.

## Contract

- Seeding a request accepts an optional parent node, which holds back its
  release, and an optional sink handler, which receives the completed request
  as a `RequestCompleted` event instead of the system keeping it.
- Handing over results at the end fails if any request is unfinished.

A parent sees only requests in and completion events out, never a child's
payloads.

## Single Instance

`single_instance` is one serving stack: one model, one runner, one scheduler.

Seeding creates a release node at the request's arrival time and an
arrival/completion pair per sub-request, wired with static edges:

```text
release ──> arrival[i] ──> complete[i] ──> arrival[j]
            (i initial)                    (j in next of i)
```

When `arrival[i]` runs, it waits `interval`, detaches its completion node, and
splices work in front of it:

- a tool call becomes one logical node lasting `duration`;
- an LLM call is enqueued into the scheduler, followed by a scheduling step.

Iterations form a self-sustaining chain:

```text
schedule ──> runner iteration ──> batch complete ──> schedule ...
                                        └──> complete[k] per finished sub-request
```

A scheduling step with nothing to admit, or with an iteration already in
flight, ends its chain; the next enqueue or batch completion starts another.
At most one iteration is in flight, and the chain exists only while there is
work. The scheduler never sees tool calls.

When every sub-request of a request has completed, the system emits its result
to the sink or keeps it.

## Composition

- **`multi_instance`** routes each whole request to one independent child
  system at simulated arrival. Children expose typed load snapshots; nested
  systems aggregate their children's loads and assigned work awaiting dispatch.
- **`moe_ep_multi_instance`** models expert parallelism with data-parallel
  attention: one shared model and EP runner, one scheduler per rank, and one
  router. A request stays on one rank for its lifetime, tool calls included.
  Iterations run as cluster waves: when any scheduler has work, every scheduler
  schedules, the runner builds one coupled iteration, and every scheduler
  completes it.
- **`pd_disaggregation`** owns prefill and decode pools of child systems plus
  its own model and network simulator. It splits a request into a prefill child
  that produces the first token and, if output remains, a decode child seeded
  with the carried context as both known and cached tokens. A KV transfer node
  between the two workers, sized by the parent's model, gates the decode
  child's release. Pools are picked round-robin. Child completions return
  through the sink and merge into one result. Only requests with a single LLM
  sub-request are supported. External requests must omit seeded progress;
  only the internal decode handoff creates it.

The P/D result retains the original interval and model provenance. Its first
decode ITL spans prefill completion through KV transfer, decode queueing, and
the first decode iteration.

`single_instance` with an EP runner and `moe_ep_multi_instance` describe
different deployments. Both charge resident weights in full per GPU. The first
has one scheduler for all ranks: request KV/state costs are averaged across
ranks, and batch limits scale with `ep`. The second has one scheduler per rank,
with raw per-device memory.

## Evolution Rules

- Build a new topology by composing systems through seeding and sinks before
  duplicating lifecycle code.
- A synthetic child carries its seeded progress explicitly; no system
  reconstructs context from earlier completions.
- Each system owns its own completion accounting; a parent only merges.
