---
name: sim-mapping
description: Map a Simthesizer task specification onto the selected codebase's state owners, dependency mechanisms, cost models, interfaces, and validation signals. Use after task-design and before sim-dev, or when evidence exposes an incorrect structural mapping.
---

# Simulator mapping

Second stage: `task-design -> sim-mapping -> sim-dev -> sim-validation`. Before implementation, map the spec's requirements to native state owners, dependencies, costs, integration sites, and observable checks.

## Inspect Simthesizer

1. Read the original request, spec, repository guidance, and relevant architecture, source, and tests. Record source revision and supplied patch identity. Check that the spec retains the requested obligations; return omissions to task-design. Verify existing maps against current code before reuse.
2. Trace a representative request through the paths affected by the feature. Locate the actual state owners, update events, execution-order mechanisms, resource/cost models, and output producers. Cite file paths and symbols that support the mapping; distinguish existing interfaces from proposed ones.
3. Identify requirements supported by existing configuration/composition and those needing implementation. Trace request DAGs through `System`, `Scheduler`, `ModelRunner`, `Model`, and compute/network simulators as applicable. Read [ARCHITECTURE.md](../../../ARCHITECTURE.md) and the relevant component documents; use event-graph dependencies for ordering.

## Write the implementation map

For each relevant requirement or modeling decision, record the following. Group decisions that share an integration path and mark irrelevant dimensions as not applicable.

| Map field | What to record |
|---|---|
| Spec decision | Stable requirement ID and source anchor from the spec; behavior or quantity with its meaning and units. Retain unresolved requirements in the map. |
| State and lifetime | Owning component and concrete state representation; creation, updates, sharing, and release; decisions that consume this state. |
| Dependencies and cost | Native interfaces or operations that order work and advance time; compute, communication, and resource-contention paths used by the feature. Trace where each semantic quantity enters these paths. |
| Integration | Existing files/symbols and evidence for their roles; what to reuse, configure, compose, extend, or add; boundary invariants to preserve. Explain why any new abstraction is needed. |
| Observation and check | Planned sample workload/configuration, native input interface, signal or state assertion, and expected result linked to its derivation. Identify instrumentation or a native fixture needed to observe the affected decision. |

Keep distinct quantities separate along their paths. If work performed differs from progress committed, locate both the cost-model input and persistent-state update; identify shortcuts that conflate them. Resolve missing meanings in `task-design`.

Trace trigger, state update, dependent work, consuming decision, and observation. Check cost frequency/ownership and dependency ordering, including affected cancellation, rollback, and completion paths.

Link each approximation's evidence, authority, and validity boundary to its component. An interface gap requires an extension or an explicit scope decision through `task-design`; keep the original requirement visible until resolved. Describing a shortcut does not establish its adequacy.

## Check and hand off

- Reconcile all requirement IDs with the spec and original request. Each maps to an implementation site and planned check, or an explicit gap. An admission effect must reach the admission decision as well as an exported metric.
- Use the [local tool guide](../../tools/validation.md) to identify comparable signals and observation gaps. Link other checks to permitted technical sources or derived invariants without claiming measured agreement.
- Save the map at the requested location and, when implementation is authorized, continue with [sim-dev](../sim-dev/SKILL.md) in this session. A mapping-only request ends with the map.
- Update the map when evidence changes ownership, dependencies, or cost placement. Return semantic corrections to task-design and code defects to sim-dev; retain the reason and update dependent artifacts.
