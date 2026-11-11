# Trace-guided validation

Use independent target-system observations to test a candidate under comparable conditions. The adapter supplies native execution and observation semantics; the comparison tools supply descriptive evidence. The task agent interprets that evidence.

1. **Establish comparability.** Verify workload/configuration identity, hardware/deployment, completion horizon, clock origin, units, sampling, scope, and metric meanings. Inspect coverage and contract issues before interpreting error. Resolve incompatible observations; do not zero-fill missing signals or fit the clock to reduce a discrepancy. Use [reference-guided validation](reference-guided.md) for claims the observations cannot support.
2. **Locate the divergence.** Inspect both traces, signed differences, error magnitude, first/last divergence, contiguous intervals, and source rows. Use a bounded overview, then inspect informative intervals in detail; avoid dumping every finding into one response. Describe how discrepancies begin, grow, change direction or recover, alongside final performance errors. Relate differences to concurrent signals and permitted workload inputs. Retain agreeing signals that weaken an explanation. Signed averages can cancel; aggregate absolute errors also hide timing. Binned differences do not identify an exact causal event or request-level ground truth.
3. **Distinguish causes.** Trace the implicated behavior through the implementation map and code. Candidate causes can include target semantics, profile inputs, resource admission, dependency ordering, cost placement, or observation mapping. Choose a controlled workload, setting change, code-path audit, or local instrumentation that distinguishes plausible causes. State the expected result before running it; test causal claims against the raw observations.
4. **Check the revision.** Return supported corrections through the routing in [sim-validation](../SKILL.md). Compare revisions on matching inputs and conditions, checking both the targeted pattern and other affected signals. Keep changed-condition diagnostics separate. Judge improvement using error magnitude, location, coverage, and changes across rounds; a small change between candidates alone does not justify completion.

For each consequential discrepancy retain a compact chain: `case/interval/source rows -> sign and evolution -> concurrent/agreeing signals -> map/code and competing causes -> expected diagnostic outcome -> observed outcome -> next action`. A changed completion time can itself produce a late sign reversal; test explanations rather than treating each interval as a separate bug.

If you judge a discrepancy material, execute the next diagnostic or supported correction and compare again. Listing possible causes or a need for more measurements does not close locally testable questions. A successful comparison command or a report marked `ANALYZED` certifies neither model accuracy nor task completion. Unavailable comparisons remain limitations, including after otherwise successful mechanism checks.

## Act on the assessment

After each TGV assessment, choose and execute the next action in the same session:

- **Investigate:** you judge a discrepancy material but its cause is unresolved. Run the distinguishing local check, recording its expectations first.
- **Revise:** evidence supports a correction. Update the relevant development stage and implementation, then repeat affected comparisons under matching conditions. Check the targeted temporal pattern and other affected signals.
- **Complete:** explain why observed differences are acceptable for the requested behavior, with requirement evidence and no pending local checks. A plateau or successful tool exit is insufficient.
- **Blocked:** identify evidence, a user choice, or a tool capability needed for the unresolved claim; explain what available checks established this limit. Complete other locally executable requirements before ending, even if they cannot resolve this blocker. Collect further real data only within the user-authorized scope.

A report listing inadequacies does not replace continued investigation or supported correction. Do not invent a fix just to produce another iteration. Resource/budget exhaustion remains incomplete, not converged. Record each assessment with `tools/validate.py decide` as described in the [tool guide](../../../tools/validation.md), then execute the next available action.
