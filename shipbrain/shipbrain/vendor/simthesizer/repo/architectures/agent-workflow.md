# Agent workflow

Simulator work follows `task-design -> sim-mapping -> sim-dev -> sim-validation`.
Skills live in `.agents/skills/`; `.claude/skills` points to the same directory.
Each stage reuses existing task artifacts and continues authorized work without
another stage approval. Small changes can keep their spec, map, and assessment
in one concise task record.

Task design owns behavior and requirement IDs. Mapping connects those IDs to
state owners, dependencies, costs, and observable checks. Development implements
the map. Validation reviews the candidate against independent observations or
criteria derived from technical sources. Corrections return to the stage that
owns the error. The same task agent owns this cycle.

`tools/validate.py` records validation decisions and checks evidence identity
and pending work. Its trace tools compare declared engine observations and
retain gaps, temporal differences, and source provenance. They do not judge
model adequacy. Request JSONL analysis remains owned by `scripts/results.py`.
Commands and observation contracts live in the
[tool guide](../.agents/tools/validation.md).

## Scope

Commands use this repository's Rust CLI, JSONL tools, and devenv/uv
environment. Engine trace collection uses the
[observability layer](observability.md). Automatic agent resumption is not
installed.
