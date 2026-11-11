---
name: sim-validation
description: Assess a Simthesizer candidate through trace-guided or reference-guided validation, diagnose discrepancies, and direct revisions. Use after sim-dev produces a candidate, after a behavior-changing revision, or to reassess an existing implementation.
---

# Simulator validation

Validation follows `task-design -> sim-mapping -> sim-dev`. The same task agent reviews modeling assumptions and evidence, performs diagnostics, and decides whether to revise, investigate, or finish. Continue without waiting for a user to find problems or approve stages.

## Establish the candidate and evidence

Read the original request, spec, map, source changes, permitted references, and raw results. Reconcile requirement IDs against the request, including promised checks and authorized scope changes. Restore dropped obligations through [task-design](../task-design/SKILL.md); resolve structural gaps through [sim-mapping](../sim-mapping/SKILL.md). Verify candidate/configuration/input identities before reusing evidence.

Use the task's validation report as a working record. For each requirement, retain:

`ID/source -> spec/map/code -> criterion and derivation -> planned check -> executed command/artifact -> expected vs observed -> disposition`

Enter expectations before new checks and append observations afterward. Retain unexecuted checks explicitly. A passing test supports only the behavior it actually distinguishes; a completion report alone is insufficient evidence.

Select evidence for each behavior being assessed:

- **Trace-guided:** compatible independent target-system observations are available. Read [trace-guided validation](references/trace-guided.md) before judging adequacy, including its temporal diagnosis and continuation rules, and read the [local tool guide](../../tools/validation.md).
- **Reference-guided:** comparable measurements or signals are unavailable. Read [reference-guided validation](references/reference-guided.md) to derive criteria and build/run small diagnostic workloads or native fixtures.

Combine modes where coverage differs. Synthetic self-comparisons establish tool behavior only. Generated diagnostic workloads test stated mechanisms under controlled assumptions; retain the requested target run separately.

## Review and act

Apply the selected procedure and assign each requirement a disposition with evidence:

| Disposition | Next action |
|---|---|
| Supported | State the tested conditions and limits; preserve reusable evidence. |
| Contradicted | Record plausible causes and a distinguishing check. Diagnose locally, then revise the affected stage. An unexplained contradiction prevents a successful completion claim. |
| Unchecked | Perform the missing local check, including a promised diagnostic workload or measurement. Lack of a real trace does not excuse available local checks. |
| Blocked | Name the missing choice, evidence, or tool capability. Ask the user about required choices outside delegation; continue independent work. When further progress needs real-system data, use collection already authorized by the user; otherwise report the missing evidence and continue independent checks. |

Route semantic corrections to task-design, ownership/dependency/cost corrections to sim-mapping, and code defects to [sim-dev](../sim-dev/SKILL.md). Update affected spec/map decisions before dependent edits; return revised candidates here and rerun affected checks under matching conditions. Preserve earlier rounds, failures, and contrary evidence. A numerical plateau alone does not establish a cause or justify completion.

No fixed iteration count or automatic accuracy threshold decides completion. Reuse unaffected evidence. Keep incomplete implementation and unexecuted checks explicit rather than declaring the task complete or waiving requirements as approximations.

## Deliver the assessment

Finalize the working report by checking original-request coverage and links to executed evidence. Summarize supported behavior, causal findings, unresolved obligations, assumptions, and the reason for revision or completion. Keep source/input identities and distinguish controlled diagnostics from target comparisons, observations from derivations, and evidence from adequacy judgments.

Record the assessment with `tools/validate.py decide`; see the [tool guide](../../tools/validation.md). The checker verifies declared state and evidence hashes. It does not judge accuracy or resume an agent automatically.
