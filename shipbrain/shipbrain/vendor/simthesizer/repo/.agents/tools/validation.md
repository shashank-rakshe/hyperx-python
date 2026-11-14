# Validation tools

Run commands from the repository root inside `devenv shell`. Use `jj` for
revision identity and changes. Keep task evidence under an explicit task
directory, for example `output/<task>/`, with separate directories per round.

## Native simulation and request results

Read [architecture](../../ARCHITECTURE.md) and the relevant component documents.
Use `cargo test --workspace` for Rust checks and `cargo fmt --all -- --check`
for formatting. Run a scenario with:

```sh
cargo run --release -- --config SCENARIO/simthesizer.toml \
  --workload WORKLOAD.jsonl --output-jsonl output/TASK/ROUND/sim.jsonl
python scripts/compare.py real=REFERENCE.jsonl sim=output/TASK/ROUND/sim.jsonl \
  --output output/TASK/ROUND/comparison.json
python scripts/draw.py real=REFERENCE.jsonl sim=output/TASK/ROUND/sim.jsonl \
  --metrics throughput cumulative --output output/TASK/ROUND/timing.svg
```

`scripts/results.py` owns result JSONL parsing, DAG timing, and serving metrics.
See [validation architecture](../../architectures/validation.md) for metric
definitions, profiling/replay commands, and supported reference workloads.
Real-system collection uses `devenv --profile vllm shell` within the user's
authorized scope. Existing profile and baseline tools remain authoritative.

Request results expose client-visible timing. They do not establish internal
running/waiting counts, KV occupancy, or engine generation counters. Native
observations use `--output-engine-trace TRACE.jsonl`; see
[observability](../../architectures/observability.md). Use reference-guided checks
when the required signal is unavailable; never fabricate an engine trace from
token latencies.

## Engine trace evidence

`tools/validate.py run-sim` captures the simulator's scheduler observations.
Its bundle contract requires fresh, independent single-LLM roots with fixed
arrivals; dependency-driven replay needs a separate comparison contract. Native
trace export supports request DAGs. Request result analysis remains in
`compare.py` and `draw.py`.

```sh
cargo build --release
python tools/validate.py run-sim --binary target/release/simthesizer \
  --config SCENARIO/simthesizer.toml --workload WORKLOAD.jsonl \
  --environment environment.json --revision REVISION \
  --duration 10 --interval 0.1 --out output/TASK/ROUND/capture
```

Choose a horizon beyond completion before capture. Keep model, hardware, serving
settings, and profile provenance in the environment evidence. The receipt records
the binary/configuration identity, command, input hashes, and completion status.
Failed runs retain an `INCOMPLETE` receipt and process log. Successful captures
include raw `trace.jsonl`, `results.jsonl`, and normalized `engine.csv`.

Native snapshots retain their component tree. Normalized metrics use JSON
pointer paths, such as `/scheduler/generation_rate` or
`/instances/0/scheduler/running_requests`; `observation_scope` retains all scheduler
paths. Only `chunked_prefill` has declared comparison semantics. Each path must
drain and its generation counter must be monotone. The total must equal the
workload's requested output. Missing signals and unsupported schedulers fail
capture. Cross-runtime comparison requires verified correspondence to these paths.

```sh
python tools/validate.py pair --reference REF_BUNDLE --candidate SIM_BUNDLE \
  --comparison comparison.json --case-id CASE --data-kind measured \
  --out output/TASK/ROUND/pair
python tools/validate.py compare output/TASK/ROUND/pair/case.json \
  --out output/TASK/ROUND/report
python tools/validate.py inspect output/TASK/ROUND/report --metric /scheduler/generation_rate \
  --start 1 --end 3 --limit 3 --offset 0
```

Pairing accepts a directory or its `bundle.json`. Each bundle contains
`engine.csv`, the exact `workload.jsonl`, `environment.json`, and `bundle.json`.
The environment requires `model`, `model_revision`, `hardware`, `deployment`,
and `serving_config`. A receipt declares:

| Field | Meaning |
|---|---|
| `schema_version`, `status` | Version `1`, status `COMPLETE` |
| `run_id`, `producer_revision` | Run and producer identities |
| `capture_duration_s` | Predeclared observation horizon, including drain policy |
| `workload_sha256` | SHA256 of workload bytes |
| `environment_sha256` | SHA256 of sorted, compact JSON from `environment.json` |
| `artifacts` | Filename to SHA256 map for the three input files |
| `clock` | `column`, `unit` (`s`, `ms`, `us`), `origin`, `basis: workload_start`, and `evidence` |
| `metrics` | Metric name to semantic declaration |
| `observation_scope` | Entity scope; must match across captures when present |
| `split`, `split_group` | Optional data partition; heldout requires explicit `--allow-heldout` |

Clock mapping is `(timestamp - origin) * unit_seconds`. Metric declarations
require `column`, `meaning`, `unit`, `observation`, `verified: true`, and
`evidence` for the semantics. Optional `dimensions` must match. Observations:

- `counter`: consecutive counter differences divided by elapsed seconds;
  resets become missing coverage.
- `gauge_hold`: previous value held until the next observation.
- `interval_mean` or `interval_count`: interval ends at the row timestamp;
  declare `start_column` or `interval_seconds`. Counts become rates.

Optional `scale` converts source values before reconstruction. Sampling gaps
exceeding `max_gap_s` remain missing. Choose bin width and gap limit from the
observation semantics. For example, `comparison.json`:

```json
{"comparison_id":"engine-evidence-v1","bin_s":0.1,"max_gap_s":0.11}
```

Optional `metrics` entries select signals and `components_to_inspect` hints.
Other declared signals are included unless `include_additional_metrics` is
false. Unavailable counterparts remain explicit.

Use fresh output directories and preserve receipts and raw inputs. The report
contains `summary.json` (coverage and provenance), `window_errors.csv` (every
aligned bin), `findings.json` (difference intervals and concurrent signals),
`summary.txt`, and `report.html` (plots with gaps).

Exit 0 means a report was produced. `ANALYZED`, `PARTIAL`, and `UNAVAILABLE`
describe evidence availability. Read contract issues and coverage before
interpreting errors. Difference intervals include floating-point noise; ranking
is within each metric. The agent judges significance and cause. Optional
`--check-acceptance` evaluates declared metric thresholds, with exits 0/2/3 for
PASS/FAIL/INCOMPLETE. Invalid input or output errors exit 4.

## Validation decisions

After an assessment, record its action and evidence. Paths are relative to the
task root; the state defaults to `validation-state.json` there.

```sh
python tools/validate.py decide --task-root output/TASK \
  --action investigate --reason 'State the discrepancy and competing causes.' \
  --next-step 'Describe the distinguishing check.' \
  --pending-check 'Describe the local check still to run.' \
  --evidence validation-report.md --evidence ROUND/report/summary.json
python tools/validate.py check --task-root output/TASK
```

Actions are `investigate`, `revise`, `complete`, and `blocked`. Investigation
and revision require `--next-step`; blockage requires `--blocker`. Complete
available checks before either terminal action. Keep unavailable evidence and
its limits in the assessment and blocker. Preserve earlier assessments and
round artifacts before updating current state.

The checker verifies evidence hashes and declared obligations. Changed/missing
evidence or pending local checks prevent terminal status. `--previous-digest`
also rejects an unchanged decision. Check exits are 0 complete, 2 blocked,
3 continued work; `decide` exits 0 when state was written, even if issues remain.
Neither command assesses scientific adequacy or starts another agent turn.
Continue authorized diagnostics and revisions in the same session.

Tool tests: `python -m unittest discover -s tests`.
