---
name: task-design
description: Turn a Simthesizer feature request into an implementation-ready behavioral specification, or review an existing spec for missing semantics and testable requirements. Use before implementation when the task contract needs clarification.
---

# Task design

First stage: `task-design -> sim-mapping -> sim-dev -> sim-validation`. Produce a behavioral contract whose requirements remain traceable to the user's request. Reuse an existing spec after checking its coverage. Read [ARCHITECTURE.md](../../../ARCHITECTURE.md) for simulator architecture.

## Establish the inputs

1. Read the request, supplied artifacts, and repository guidance. Identify required behavior, supported configurations, outputs, and exclusions. Inspect actual input records before describing their schema.
2. Record relevant workload, model/revision, configuration, profile, and observation identities. Research technical facts from permitted authoritative sources and retain their locations/revisions.
3. Separate established facts from choices the request leaves open. Supplied workloads, profiles, and measurements establish inputs; they do not by themselves authorize modeling assumptions.

## Resolve choices with the user

For an underspecified request, initiate clarification before finalizing the spec or starting dependent mapping or implementation. Inspect the supplied material first, then ask about the remaining performance-relevant choices: mechanism scope, work versus committed progress, state lifetime, metric boundaries, permitted approximations, and treatment of missing costs, as applicable. Cite facts already resolved by the request or references instead of asking for reconfirmation.

Confirm the intended support scope when it is unspecified: only the supplied configurations, or configurable mechanism parameters, models, parallelism, and hardware with compatible inputs. Separate required implementation support from the configurations covered by current measurements. Limited profiles or statistics do not authorize restricting the implementation to those cases; ask before making that restriction, and record unvalidated configurations separately.

Ask concrete questions: name the open choice, explain how alternatives change simulated behavior, and offer a recommendation when useful. Ask only about unresolved choices that change required behavior. Continue independent work while waiting; use asynchronous questions when available.

Honor choices and discretion already granted in the conversation. Record consequential answers and assumptions beside the affected requirement. Choose internal implementation details autonomously. Ask before changing requested semantics or narrowing support; fitting measurements does not authorize either.

Revisit unanswered choices after each reply and ask follow-up questions when an answer leaves a consequential ambiguity. Advance once each consequential choice is sourced, answered, or within granted discretion; retain unavailable evidence and the agreed approximation boundary separately.

## Define the behavior

Write a concise spec containing:

- **Scope:** required behavior, supported configurations, fidelity boundary, and exclusions.
- **Mechanism:** state/lifetime, events, transitions, dependencies, resource interactions, and quantities determining work or cost. State the user's rules for hypothetical mechanisms; cite technical sources for existing systems.
- **Inputs and outputs:** paths, schema fields, meanings, units, sampling, and completion conditions. Distinguish internal decision state from exported measurements.
- **Requirements and checks:** assign stable IDs and retain an anchor to each original request item, supplied source, or user decision. Carry these IDs into the map and validation report.
- **Uncertainty:** separate sourced facts, derived consequences, delegated approximations, and unresolved choices or evidence gaps.

Use the following shape for requirements; add rows only for task-relevant behavior:

| Requirement ID and source | Controlled scenario | Expected behavior and basis | Check and evidence needed |
|---|---|---|---|
| R1: requested admission effect | Capacity between the old and new request footprints | Different admission decisions, derived from capacity and ownership rules | Small pressure workload and admission observations |

Plan small sample workloads that distinguish intended behavior from a plausible shortcut. Identify controlled arrivals, work sizes, shared state, or capacity as relevant, and the observable that would expose the error. Development materializes these cases using the simulator's native inputs; diagnostic cases supplement the supplied target workload.

For consequential derived quantities, show a small worked calculation from the stated rules, including assumptions and units. Keep illustrative values distinct from target settings. Do not invent measured accuracy targets without reference evidence.

Documenting an approximation does not authorize dropping a requirement. Preserve the original obligation when recording an amendment, its authority, and affected IDs. Ask about scope changes outside explicit delegation; an implementation gap remains incomplete until resolved.

## Hand off

- Compare the requirement inventory against the original request, including outputs, transitions, and required checks. Resolve conflicts and retain uncovered obligations explicitly.
- Save the spec at the requested location with source anchors, input identities, derivations, assumptions, and blockers. Missing reference data does not resolve missing task intent.
- When implementation is requested, continue with [sim-mapping](../sim-mapping/SKILL.md) in this session. A spec-only request ends with the spec. Leave native implementation structure to mapping, and continue authorized stages without another approval.
