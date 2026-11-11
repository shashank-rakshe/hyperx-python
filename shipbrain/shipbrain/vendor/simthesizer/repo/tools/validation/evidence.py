"""Descriptive evidence only: no accuracy verdict or inferred root cause."""

from __future__ import annotations

import bisect
import math


def weighted_quantile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    threshold = fraction * sum(weight for _, weight in ordered)
    cumulative = 0.0
    for value, weight in ordered:
        cumulative += weight
        if cumulative >= threshold:
            return value
    return ordered[-1][0]


def series_statistics(bins, edges):
    observed = [
        (row["value"], right - left)
        for row, left, right in zip(bins, edges, edges[1:])
        if row["value"] is not None
    ]
    duration = sum(weight for _, weight in observed)
    integral = sum(value * weight for value, weight in observed)
    return {
        "observed_duration_s": duration,
        "coverage_fraction": duration / (edges[-1] - edges[0]),
        "time_weighted_mean": integral / duration if duration else None,
        "integral_over_observed_bins": integral if observed else None,
        "min_bin_mean": min((v for v, _ in observed), default=None),
        "max_bin_mean": max((v for v, _ in observed), default=None),
        "p50_bin_mean": weighted_quantile(observed, 0.5),
        "p95_bin_mean": weighted_quantile(observed, 0.95),
    }


def discrepancy_statistics(windows):
    valid = [w for w in windows if w["signed_error"] is not None]
    if not valid:
        return {
            "peak_absolute_error": None,
            "first_difference_s": None,
            "last_difference_end_s": None,
        }
    duration = sum(w["end_s"] - w["start_s"] for w in valid)
    weighted = [(w["absolute_error"], w["end_s"] - w["start_s"]) for w in valid]
    different = [w for w in valid if w["difference_observed"]]
    peak = max(valid, key=lambda w: w["absolute_error"])
    return {
        "rmse": math.sqrt(
            sum(w["signed_error"] ** 2 * (w["end_s"] - w["start_s"]) for w in valid)
            / duration
        ),
        "absolute_error_p50": weighted_quantile(weighted, 0.5),
        "absolute_error_p95": weighted_quantile(weighted, 0.95),
        "absolute_error_p99": weighted_quantile(weighted, 0.99),
        "observed_difference_duration_s": sum(
            w["end_s"] - w["start_s"] for w in different
        ),
        "overprediction_duration_s": sum(
            w["end_s"] - w["start_s"] for w in different if w["signed_error"] > 0
        ),
        "underprediction_duration_s": sum(
            w["end_s"] - w["start_s"] for w in different if w["signed_error"] < 0
        ),
        "first_difference_s": different[0]["start_s"] if different else None,
        "last_difference_end_s": different[-1]["end_s"] if different else None,
        "peak_absolute_error": {
            k: peak[k]
            for k in [
                "start_s",
                "end_s",
                "reference",
                "candidate",
                "signed_error",
                "absolute_error",
                "reference_rows",
                "candidate_rows",
            ]
        },
    }


def difference_windows(name, windows, components):
    """Group consecutive nonzero differences by direction, independent of tolerance.

    Every bin remains in the full window table. Numerically nonzero includes
    floating-point noise; the agent assesses importance rather than a threshold.
    """
    groups = []
    current = []
    direction = None
    for w in windows + [{"difference_observed": False}]:
        sign = (
            (1 if w["signed_error"] > 0 else -1) if w["difference_observed"] else None
        )
        if current and sign != direction:
            groups.append(current)
            current = []
        if sign is not None:
            current.append(w)
        direction = sign
    findings = []
    for group in groups:
        duration = sum(w["end_s"] - w["start_s"] for w in group)
        signed = sum(w["signed_error"] * (w["end_s"] - w["start_s"]) for w in group)
        findings.append(
            {
                "kind": "observed_difference",
                "metric": name,
                "start_s": group[0]["start_s"],
                "end_s": group[-1]["end_s"],
                "duration_s": duration,
                "bins": len(group),
                "mean_signed_error": signed / duration,
                "absolute_error_area": sum(
                    w["absolute_error"] * (w["end_s"] - w["start_s"]) for w in group
                ),
                "direction": "overprediction" if signed > 0 else "underprediction",
                "peak_absolute_error": discrepancy_statistics(group)[
                    "peak_absolute_error"
                ],
                "evidence": {
                    role + "_rows": sorted(
                        {r for w in group for r in w[role + "_rows"]}
                    )
                    for role in ("reference", "candidate")
                },
                "components_to_inspect": components,
                "causal_status": "not_established",
                "interpretation": "A measured difference at the selected time resolution; practical importance is for the agent to assess.",
            }
        )
    return findings


def attach_context(findings, by_metric, edges, reports):
    for finding in findings:
        left = bisect.bisect_left(edges, finding["start_s"])
        right = bisect.bisect_left(edges, finding["end_s"])
        context = {}
        cooccurring = []
        for name, report in reports.items():
            rows = by_metric.get(name, [])[left:right]
            comparable = [w for w in rows if w["signed_error"] is not None]
            duration = sum(w["end_s"] - w["start_s"] for w in comparable)
            item = {
                "unit": report["unit"],
                "meaning": report["meaning"],
                "paired_coverage_fraction": duration / finding["duration_s"],
                "reference_mean": None,
                "candidate_mean": None,
                "mean_signed_error": None,
                "comparison_unavailable_reasons": report.get("reasons", []),
            }
            if duration:
                for key, field in [
                    ("reference_mean", "reference"),
                    ("candidate_mean", "candidate"),
                    ("mean_signed_error", "signed_error"),
                ]:
                    item[key] = (
                        sum(w[field] * (w["end_s"] - w["start_s"]) for w in comparable)
                        / duration
                    )
                item["source_rows"] = {
                    role: sorted({r for w in comparable for r in w[role + "_rows"]})
                    for role in ("reference", "candidate")
                }
            context[name] = item
            if name != finding["metric"] and any(
                w["difference_observed"] for w in comparable
            ):
                cooccurring.append(name)
        finding["concurrent_signals"] = context
        finding["cooccurring_metrics"] = sorted(cooccurring)
        finding["questions_for_agent"] = [
            "Does this interval align with an input burst, admission transition, or drain phase? Consult permitted workload inputs; no request truth is inferred here.",
            "Which concurrent signals support or contradict your proposed mechanism? Coincidence does not establish causality.",
            "What additional observation or diagnostic workload would distinguish the plausible explanations?",
        ]
