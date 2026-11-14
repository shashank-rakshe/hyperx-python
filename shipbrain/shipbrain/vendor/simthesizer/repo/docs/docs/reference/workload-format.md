---
title: Workload format
---

# Workload format

Workload JSONL is the simulator's only input format, and result JSONL is the
shared output of the simulator and the vLLM baseline. Both hold one request DAG
per row.

## Request

| Field | Meaning |
|---|---|
| `request_id` | Unique ID |
| `arrival_time` | Seconds from the start of the run |
| `initial` | Root sub-request indices: the indices no `next` points to, in ascending order |
| `sub_requests` | Non-empty list of `llm` and `tool_call` nodes |

## Sub-request

| Field | Applies to | Meaning |
|---|---|---|
| `kind` | all | `llm` or `tool_call` |
| `next` | all | Indices of successor sub-requests |
| `input_tokens`, `output_tokens` | all | For `llm`, the full prompt length of this step and the tokens to generate. For `tool_call`, use 0. |
| `interval` | all | Optional, default 0. Delay before the node starts, after the request arrives (roots) or after every predecessor finishes: think time or invocation overhead. |
| `duration` | `tool_call` | Optional, default 0. Wall-clock time; a tool call occupies no device. |
| `input_token_ids`, `output_token_ids` | `llm` | Optional token trace, needed for prefix caching |
| `known_tokens`, `kv_tokens` | `llm` | Optional seeded progress, set together; omitted in normal workloads |
| `model` | `llm` | Optional provenance; never affects simulation |

Each `llm` sub-request is self-contained. Runtime never derives context from
predecessors; reuse across steps is found by the prefix cache from token IDs.
Unknown fields, cycles, and invalid indices are rejected.

## Example

An agentic request: an LLM call, a tool call, then a follow-up LLM call.

```json
{"request_id": 0, "arrival_time": 0.0, "initial": [0], "sub_requests": [
  {"kind": "llm", "input_tokens": 2961, "output_tokens": 17, "next": [1], "interval": 0.0},
  {"kind": "tool_call", "input_tokens": 0, "output_tokens": 0, "duration": 0.00007, "next": [2], "interval": 0.0},
  {"kind": "llm", "input_tokens": 39, "output_tokens": 16, "next": [], "interval": 0.00036}
]}
```

Real rows are one line each.

## Results

A result row repeats the request's DAG and adds a `token_latency` array to every
`llm` sub-request. Entry 0 is the time from entering the scheduler to the first
token; later entries are inter-token latencies. `scripts/results.py`
reconstructs absolute token times by walking the DAG from `arrival_time`.

Source of truth:
[`architectures/workload.md`](https://github.com/casys-kaist/Simthesizer/blob/main/architectures/workload.md).
