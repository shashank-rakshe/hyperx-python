# Observability

Components own observation meaning. `Module::observe` returns a read-only JSON
value; `null` means unavailable. Systems compose child snapshots using their
configuration field names and array positions. A new field or component needs
no engine metric registry or new trace type.

`Engine::run_with_observer` calls a consumer after every event at the same time
has run, including newly created zero-duration descendants. It also reports
time zero for delayed or empty workloads. The callback receives the engine
time and a shared system reference. It adds no graph nodes or modeled cost.
Ordinary `run` uses the same event loop with an empty callback.

The CLI's `--output-engine-trace PATH` writes JSONL:

```json
{"time_s":0.0,"state":{"scheduler":{"running_requests":1,"waiting_requests":0,"generation_tokens_total":0}}}
```

Each row contains a complete snapshot. Unchanged intermediate snapshots are
omitted; the first and final engine times remain. Writing retains one snapshot
in memory and uses a temporary file. The file is published only after a
successful simulation and flush; existing trace files are never replaced.

## Scheduler signals

`chunked_prefill` exposes:

| Signal | Meaning |
|---|---|
| `running_requests` | Admitted, unfinished LLM sub-requests, including those retaining state outside the current batch |
| `waiting_requests` | Enqueued sub-requests without admission, including preempted requests |
| `generation_tokens_total` | Committed token emissions since scheduler creation |

An admission set keyed by completion node owns membership; its size gives the
running count. Waiting is queue length minus that size. Admission, preemption,
and completion update the set. Token generation increments at the emission
site, including the final prefill chunk. Cached input and scheduled work do not
increment it. Routing load snapshots retain their existing batch-based meaning.

## Composition and comparison

Single-instance snapshots contain `scheduler`; EP contains `schedulers` in
configured order. `multi_instance` contains `instances`; P/D contains
`prefill_instances` and `decode_instances`. These paths compose recursively and
identify physical scheduler state without cross-instance aggregation. P/D
counts the first output token in the prefill pool and the remaining emissions
in the decode pool. Native capture supports the system's ordinary request DAGs.

`tools/validate.py run-sim` converts these snapshots into comparison bundles.
The adapter selects the declared scheduler signals and retains configuration
paths as metric dimensions. It samples states with a hold rule and preserves
counters; only a drained run may extend idle to a predeclared horizon. Unknown
scheduler semantics or missing observations fail capture. Additional native
fields remain in the raw trace until a comparison mapping defines their meaning.

The bundle runner currently accepts fresh, independent single-LLM roots with
fixed arrivals. This restriction belongs to the comparison contract. Engine
observation itself supports nested systems and dependent requests. A reference
with different component identities needs an explicit correspondence before
pairing. See the [tool guide](../.agents/tools/validation.md) for commands.
