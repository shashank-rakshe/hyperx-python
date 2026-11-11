# Reference-guided validation

Use technical evidence and controlled local experiments when comparable target-system observations are unavailable. The task agent derives expectations, creates diagnostic inputs, and checks the candidate. This establishes support and validity boundaries, not measured target-system accuracy.

## Derive the criterion

Return to the original requirement and permitted algorithm descriptions, reference implementations, model facts, profiles, or publications. Retain source locations/revisions and applicable conditions; respect any task-specific restrictions on reference data. For hypothetical mechanisms, use the user's declared rules. Published numerical results require comparable workloads, configurations, metrics, and hardware.

Prioritize contradictions, consequential assumptions, and requirements lacking distinguishing evidence. Before reusing a development test as proof, enter in the working validation report:

`requirement/source -> facts and assumptions -> derivation -> expected observation -> plausible error this check distinguishes`

Derive a number, bound, ordering, or qualitative relationship from those rules. Recheck the spec's derivation itself: copying the implementation's formula into an expected value cannot validate that formula. For reconstructed quantities, check the property they claim to preserve. For stochastic behavior, derive an exact expectation where possible or justify sampling and tolerance before execution; deterministic extremes alone do not validate intermediate behavior.

## Build and run a distinguishing case

Create a small sample workload/configuration that exercises the affected implementation. Control request count, arrivals, work sizes, shared state, capacity, or randomness as needed to separate plausible explanations. Use Simthesizer workload JSONL, scenario TOML, and the commands in the [tool guide](../../../tools/validation.md). Save inputs or a deterministic generator, configuration, expected assertions, and the run command in the task's diagnostic artifacts.

If a workload cannot isolate or expose the behavior, use a native fixture or local instrumentation with the same criterion. Check the consuming decision or state transition, including relevant allocation/release, dependency ordering, profile inputs, and charging frequency. Reuse existing cases only after verifying their derivation, conditions, and distinguishing assertions. Preserve supplied target inputs; label synthetic workloads, costs, and assumptions, and run the requested target separately.

### Worked diagnostic example

Suppose the declared mechanism is one non-preemptive FIFO worker, with no batching, overlap, or overhead and controlled service costs:

| Request | Arrival | Service cost | Expected completion |
|---|---|---|---|
| A | 0 s | 4 s | 4 s |
| B | 1 s | 2 s | 6 s |

A finishes at `0 + 4`; B starts at `max(1, 4)` and finishes two seconds later, with three seconds of waiting. Generate these arrivals and controlled costs in a supported native fixture, run the candidate, and compare both completions and B's waiting time. A shortcut that starts B on arrival would finish it at 3 s; checking only that two requests completed would miss it. Apply these expectations only when the declared serial conditions hold; derive different expectations for batching or concurrent execution.

## Compare, diagnose, and reassess

Append actual observations and raw artifact links to the pre-recorded expectation. Account for contrary evidence and uncontrolled scheduling/load changes. Observation off/on claims require matched behavior checks; required wall-time claims need repeated matched runs including output cost and investigation of material unexplained overhead.

On contradiction, identify the affected decision and next distinguishing action; route corrections through [sim-validation](../SKILL.md). Retain a supported bug's reproducer failing before correction and passing afterward. Reconcile promised checks with executed evidence, then record remaining assumptions and unavailable real-system evidence using the parent skill's dispositions. Complete available local checks before attributing uncertainty to missing measurements; collect additional real reference data only within the user-authorized scope.
