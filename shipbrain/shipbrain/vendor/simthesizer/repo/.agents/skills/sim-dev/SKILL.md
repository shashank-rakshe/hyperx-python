---
name: sim-dev
description: Implement, extend, or debug Simthesizer behavior using Simthesizer's architecture and task evidence. Use for simulator mechanisms, model support, scheduling, resource accounting, and native observations in this repository.
---

# Simulator development

Third stage: `task-design -> sim-mapping -> sim-dev -> sim-validation`. Implement the spec through its map, retaining requirement IDs and evidence. Read [ARCHITECTURE.md](../../../ARCHITECTURE.md), the relevant component documents, and the [local tool guide](../../tools/validation.md).

## Repository boundaries

- The engine owns virtual time. Systems and runners express work through graph nodes; components never advance time directly.
- Extend registered traits and `register_*!` implementations before adding abstractions. Keep IO normalization at the CLI and profile loaders.
- Models need their own `Model` implementation and matching profiles. Verify explicit dimensions in the real model config; never alias a similar model.
- Profile JSONL preserves per-layer costs and batch shapes. Trace layer-to-component mappings in scenario TOML; report missing coverage.
- Use measured or justified effective link bandwidth for the target topology. A theoretical peak does not establish contention behavior.

## Establish what must change

1. Read the task spec and implementation map. If the map is missing or stale, use [sim-mapping](../sim-mapping/SKILL.md) before dependent code changes. Resolve missing target semantics through [task-design](../task-design/SKILL.md). Reuse complete artifacts and already supplied choices.
2. Inspect the relevant workload records, model configuration, profiles, and runtime settings. For parameters affecting this change, record the required value, effective value, source, and any mismatch in the task notes. Verify explicit shape fields before deriving dimensions. Record unknown facts as unknown; use approximations only within the agreed scope.
3. Verify mapped interfaces and invariants against working code. Keep every required behavior linked to its implementation or an explicit gap; retain source anchors and authorized amendments.

Ask only about missing target choices or evidence that changes required behavior. Continue work independent of the answer. Choose internal implementation details yourself and record consequential assumptions.

## Implement and check the mechanism

- Update the state and decisions identified in the map. A required behavioral effect must reach its consuming decision, not only a configuration field or report. Preserve the simulator's permitted abstraction and approximation level.
- Keep native input normalization at the repository's IO boundaries. Define conversions between internal state and exported metrics, including units, clock, sampling order, and aggregation where relevant.
- Use authoritative model/configuration facts and compatible profiling evidence for the dimensions or costs being changed. Report missing coverage instead of silently substituting a different model or deployment. Keep output-fitting corrections separate from mechanism changes and use calibration only when the task explicitly calls for it.
- Materialize the planned sample workloads/configurations in the simulator's native format. Before execution, record expected observations and their derivation from the requirement. Run the small cases against the changed decision or state transition, then relevant existing tests and the requested target workload. Save inputs or generators, commands, and raw results. Keep synthetic diagnostics separate from supplied workloads/profiles and label their assumptions.
- For a resource-accounting change, follow allocation, growth, sharing, release, and eviction where those operations exist. For an observation-only change, check that enabling export preserves simulation results and event ordering. Measure runtime overhead when the change affects a hot path.

Check changes for undeclared approximations, unexplained constants, and changed ownership or execution paths. Fix code defects here; return structural corrections to sim-mapping and semantic corrections to task-design. Update dependent artifacts and relevant architecture documentation.

## Hand off the candidate

Retain the spec/map, source changes, runnable configuration, input identities, diagnostic inputs, commands/results, approximations, and incomplete behavior at the task's existing locations. For each requirement, distinguish planned checks from checks actually executed; link implemented behavior to its map entry and code.

After implementation and behavior-changing revisions, continue with [sim-validation](../sim-validation/SKILL.md) in this session. It independently assesses modeling assumptions and evidence through trace-guided or reference-guided validation. Passing development tests produces a candidate for review. Address findings at the relevant stage and return the revised candidate to validation without another approval.
