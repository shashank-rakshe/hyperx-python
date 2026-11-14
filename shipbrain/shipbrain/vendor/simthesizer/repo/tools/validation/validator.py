"""Deterministic, dependency-free validator for interval engine observations."""

from __future__ import annotations

import csv
import hashlib
import itertools
import json
import math
from pathlib import Path
from typing import Any

from . import __version__


class ContractError(ValueError):
    pass


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def number(value: Any, label: str) -> float:
    try:
        n = float(value)
    except (TypeError, ValueError) as exc:
        raise ContractError(f"{label}: expected a finite number") from exc
    if not math.isfinite(n):
        raise ContractError(f"{label}: expected a finite number")
    return n


def resolve(root: Path, name: str) -> Path:
    return (root / name).resolve()


def load_source(root: Path, source: dict) -> dict:
    path = resolve(root, source["path"])
    with path.open(newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        columns = reader.fieldnames or []
        rows = list(reader)
    if not rows:
        raise ContractError(f"{path}: empty engine trace")
    clock = source["clock"]
    column = clock["column"]
    if column not in columns:
        raise ContractError(f"{path}: missing clock column {column}")
    factor = {"s": 1.0, "ms": 0.001, "us": 0.000001}.get(clock["unit"])
    if factor is None:
        raise ContractError("clock unit must be s, ms, or us")
    origin = clock.get("origin")
    times = None
    if origin is not None:
        origin = number(origin, "clock.origin")
        times = [
            (number(row[column], f"{path}:{i + 2}:timestamp") - origin) * factor
            for i, row in enumerate(rows)
        ]
        if any(b <= a for a, b in itertools.pairwise(times)):
            raise ContractError(f"{path}: timestamps must be strictly increasing")
    return {
        "rows": rows,
        "columns": columns,
        "times": times,
        "path": str(path),
        "sha256": digest(path),
        "factor": factor,
        "config": source,
    }


def source_segments(source: dict, spec: dict) -> tuple[list[tuple], list[dict]]:
    """Return non-overlapping [start,end) segments, with source row evidence."""
    if source["times"] is None:
        raise ContractError("workload clock origin is unavailable")
    column = spec["column"]
    if column not in source["columns"]:
        raise ContractError(f"missing metric column: {column}")
    observation = spec["observation"]
    allowed = {"interval_mean", "interval_count", "counter", "gauge_hold"}
    if observation not in allowed:
        raise ContractError(f"unsupported observation: {observation}")
    gap_limit = number(spec["max_gap_s"], "max_gap_s")
    if gap_limit <= 0:
        raise ContractError("max_gap_s must be positive")
    scale = number(spec.get("scale", 1.0), "scale")
    values, issues = [], []
    for i, row in enumerate(source["rows"]):
        raw = row.get(column)
        if raw is None or raw.strip() == "":
            values.append(None)
            issues.append({"kind": "missing_value", "row": i + 2})
        else:
            value = number(raw, f"{column}:row {i + 2}") * scale
            if spec.get("nonnegative", True) and value < 0:
                values.append(None)
                issues.append({"kind": "negative_value", "row": i + 2})
            else:
                values.append(value)
    segments = []
    times = source["times"]
    clock = source["config"]["clock"]
    for i, end in enumerate(times):
        rows = [i + 2]
        if observation in {"counter", "gauge_hold"}:
            if i == 0:
                continue
            start = times[i - 1]
            rows = [i + 1, i + 2]
            if observation == "counter":
                if values[i] is None or values[i - 1] is None:
                    continue
                delta = values[i] - values[i - 1]
                if delta < 0:
                    issues.append({"kind": "counter_reset", "rows": rows})
                    continue
                value = delta / (end - start)
            else:
                if values[i - 1] is None:
                    continue
                value = values[i - 1]
        else:
            if values[i] is None:
                continue
            if "start_column" in spec:
                raw = source["rows"][i].get(spec["start_column"])
                start = (number(raw, "interval start") - clock["origin"]) * source[
                    "factor"
                ]
            elif "interval_seconds" in spec:
                start = end - number(spec["interval_seconds"], "interval_seconds")
            else:
                raise ContractError(
                    "interval observations require start_column or interval_seconds"
                )
            value = values[i]
            if end <= start:
                raise ContractError("interval end must be greater than start")
            if observation == "interval_count":
                value /= end - start
        if end - start > gap_limit + 1e-9:
            issues.append(
                {"kind": "sampling_gap", "start_s": start, "end_s": end, "rows": rows}
            )
            continue
        if segments and start < segments[-1][1] - 1e-9:
            raise ContractError(
                "overlapping intervals; rolling averages need a separate adapter"
            )
        segments.append((start, end, value, rows))
    return segments, issues


def rebin(segments: list[tuple], edges: list[float]) -> list[dict]:
    """Integrate declared constant segments; do not extrapolate over gaps/tails."""
    result = []
    j = 0
    for left, right in itertools.pairwise(edges):
        while j < len(segments) and segments[j][1] <= left:
            j += 1
        k, integral, duration, rows = j, 0.0, 0.0, set()
        while k < len(segments) and segments[k][0] < right:
            a, b, value, source_rows = segments[k]
            overlap = max(0.0, min(b, right) - max(a, left))
            integral += overlap * value
            duration += overlap
            if overlap:
                rows.update(source_rows)
            k += 1
        complete = duration >= (right - left) * (1 - 1e-8)
        result.append(
            {
                "value": integral / duration if complete and duration else None,
                "coverage": min(1.0, duration / (right - left)),
                "rows": sorted(rows),
            }
        )
    return result


def validate_contract(case: dict, root: Path, sources: dict) -> tuple[list[str], dict]:
    issues = []
    evidence = {}
    if case.get("schema_version") != 1:
        raise ContractError("schema_version must be 1")
    workload = case.get("workload", {})
    expected_hash = None
    if workload.get("path"):
        path = resolve(root, workload["path"])
        expected_hash = digest(path)
        evidence["workload"] = {"path": str(path), "sha256": expected_hash}
    else:
        issues.append("workload artifact is unavailable")
    if workload.get("replay_mode") != "fixed_arrivals":
        issues.append(
            "v1 requires fixed request arrivals; dependency-driven replay needs a separate contract"
        )
    environment = case.get("environment")
    required_env = {
        "model",
        "model_revision",
        "hardware",
        "deployment",
        "serving_config",
    }
    if not isinstance(environment, dict) or any(
        k not in environment or environment[k] is None for k in required_env
    ):
        issues.append("environment specification is incomplete")
    env_hash = hashlib.sha256(
        json.dumps(environment, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    evidence["environment_sha256"] = env_hash
    for role, source in sources.items():
        cfg = source["config"]
        if cfg.get("observation_scope") != case.get("observation_scope"):
            issues.append(
                f"{role}: observation scope differs; entity correspondence is unverified"
            )
        if cfg.get("artifact_sha256") and cfg["artifact_sha256"] != source["sha256"]:
            issues.append(f"{role}: engine artifact digest differs from paired capture")
        if expected_hash is None or cfg.get("workload_sha256") != expected_hash:
            issues.append(f"{role}: workload digest is absent or differs")
        if cfg.get("environment_sha256") != env_hash:
            issues.append(f"{role}: environment digest is absent or differs")
        if not cfg.get("run_id") or not cfg.get("producer_revision"):
            issues.append(f"{role}: run ID / producer revision is unavailable")
        if (
            cfg["clock"].get("basis") != "workload_start"
            or not cfg["clock"].get("evidence")
            or source["times"] is None
        ):
            issues.append(f"{role}: workload-start clock mapping is unverified")
        evidence[role] = {k: source[k] for k in ("path", "sha256")}
        evidence[role].update(
            {
                k: cfg.get(k)
                for k in (
                    "run_id",
                    "producer_revision",
                    "clock",
                    "workload_sha256",
                    "environment_sha256",
                )
            }
        )
    return issues, evidence


def compare(case_path: Path, *, check_acceptance: bool = False) -> dict:
    from .evidence import (
        attach_context,
        difference_windows,
        discrepancy_statistics,
        series_statistics,
    )

    case_path = case_path.resolve()
    case = json.loads(case_path.read_text())
    root = case_path.parent
    if not case.get("case_id"):
        raise ContractError("case_id is required")
    sources = {
        role: load_source(root, case[role]) for role in ("reference", "candidate")
    }
    issues, evidence = validate_contract(case, root, sources)
    for role, receipt in case.get("bundle_evidence", {}).items():
        if digest(resolve(root, receipt["path"])) != receipt["sha256"]:
            issues.append(f"{role}: capture receipt changed after pairing")
    period = case["comparison"]
    start, end = number(period["start_s"], "start_s"), number(period["end_s"], "end_s")
    width = number(period["bin_s"], "bin_s")
    if end <= start or width <= 0 or math.ceil((end - start) / width) > 100000:
        raise ContractError("invalid comparison window or more than 100000 bins")
    edges = [start + i * width for i in range(math.ceil((end - start) / width))] + [end]
    if period.get("reconstruction") != "piecewise_constant":
        raise ContractError("explicit reconstruction=piecewise_constant is required")
    if not period.get("window_evidence"):
        issues.append("comparison window / completion policy has no provenance")
    reports, windows, findings, by_metric = {}, [], [], {}
    specs = case.get("metrics", [])
    if not specs:
        raise ContractError("at least one metric is required")
    if len({m["name"] for m in specs}) != len(specs):
        raise ContractError("metric names must be unique")
    for metric in specs:
        name = metric["name"]
        report = {
            "unit": metric["unit"],
            "meaning": metric["meaning"],
            "required": metric.get("required", True),
        }
        reports[name] = report
        per_role, errors = {}, []
        for role, source in sources.items():
            spec = source["config"].get("metrics", {}).get(name)
            if not spec:
                errors.append(f"{role}: metric unavailable")
                continue
            report[role + "_observation"] = spec
            if (
                spec.get("meaning") != metric["meaning"]
                or spec.get("unit") != metric["unit"]
            ):
                errors.append(
                    f"{role}: metric meaning/unit differs from comparison contract"
                )
                continue
            if spec.get("dimensions", {}) != metric.get("dimensions", {}):
                errors.append(
                    f"{role}: metric dimensions differ from comparison contract"
                )
                continue
            if spec.get("verified") is not True or not spec.get("evidence"):
                errors.append(f"{role}: observation semantics are unverified")
                continue
            try:
                segments, data_issues = source_segments(source, spec)
                report[role + "_data_issues"] = data_issues
                per_role[role] = rebin(segments, edges)
                report[role + "_statistics"] = series_statistics(per_role[role], edges)
            except ContractError as exc:
                errors.append(f"{role}: {exc}")
        if issues:
            errors.append(
                "Input comparability is not established; paired differences are withheld. See contract_issues."
            )
        if errors:
            report.update(
                status="INCOMPARABLE" if check_acceptance else "UNAVAILABLE",
                analysis_status="UNAVAILABLE",
                reasons=errors,
            )
            continue
        # Only an explicitly requested acceptance check interprets thresholds.
        acceptance = metric.get("acceptance") if check_acceptance else None
        if acceptance is not None:
            atol = number(acceptance["absolute_tolerance"], "absolute_tolerance")
            rtol = number(acceptance["relative_tolerance"], "relative_tolerance")
            bad_limit = number(
                acceptance["max_bad_duration_fraction"], "max_bad_duration_fraction"
            )
            if atol < 0 or rtol < 0 or not 0 <= bad_limit <= 1:
                raise ContractError(
                    "acceptance tolerances must be nonnegative; fraction must be in [0,1]"
                )
        eps = number(metric.get("relative_error_floor", 1e-12), "relative_error_floor")
        if eps < 0:
            raise ContractError("relative_error_floor must be nonnegative")
        metric_windows = []
        signed_area = absolute_area = observed_duration = 0.0
        for i, (left, right) in enumerate(itertools.pairwise(edges)):
            ref, sim = per_role["reference"][i], per_role["candidate"][i]
            rv, sv = ref["value"], sim["value"]
            row = {
                "metric": name,
                "start_s": left,
                "end_s": right,
                "reference": rv,
                "candidate": sv,
                "reference_coverage": ref["coverage"],
                "candidate_coverage": sim["coverage"],
                "reference_rows": ref["rows"],
                "candidate_rows": sim["rows"],
                "signed_error": None,
                "absolute_error": None,
                "relative_error": None,
                "difference_observed": None,
                "exceeds_tolerance": None,
            }
            if rv is not None and sv is not None:
                error = sv - rv
                row.update(
                    signed_error=error,
                    absolute_error=abs(error),
                    relative_error=error / abs(rv) if abs(rv) > eps else None,
                    difference_observed=error != 0.0,
                    exceeds_tolerance=abs(error) > atol + rtol * abs(rv) + 1e-12
                    if acceptance
                    else None,
                )
                signed_area += error * (right - left)
                absolute_area += abs(error) * (right - left)
                observed_duration += right - left
            row.update(
                signed_error_area_over_observed_bins=signed_area,
                absolute_error_area_over_observed_bins=absolute_area,
                cumulative_observed_duration_s=observed_duration,
            )
            metric_windows.append(row)
        windows.extend(metric_windows)
        by_metric[name] = metric_windows
        valid = [w for w in metric_windows if w["signed_error"] is not None]
        duration = sum(w["end_s"] - w["start_s"] for w in valid)
        ref_area = sum(abs(w["reference"]) * (w["end_s"] - w["start_s"]) for w in valid)
        error_area = sum(
            w["absolute_error"] * (w["end_s"] - w["start_s"]) for w in valid
        )
        bad_duration = sum(
            w["end_s"] - w["start_s"] for w in valid if w["exceeds_tolerance"]
        )
        bad_fraction = bad_duration / duration if duration and acceptance else None
        report.update(
            comparable_bins=len(valid),
            total_bins=len(metric_windows),
            comparable_duration_s=duration,
            coverage_fraction=duration / (end - start),
            mae=error_area / duration if duration else None,
            signed_bias=signed_area / duration if duration else None,
            wape=error_area / ref_area if ref_area > eps * duration else None,
            absolute_error_area_over_observed_bins=error_area,
            signed_error_area_over_observed_bins=signed_area,
            relative_error_floor=eps,
            relative_error_undefined_bins=sum(
                w["relative_error"] is None for w in valid
            ),
            missing_windows=[
                {
                    "start_s": w["start_s"],
                    "end_s": w["end_s"],
                    "reference_coverage": w["reference_coverage"],
                    "candidate_coverage": w["candidate_coverage"],
                }
                for w in metric_windows
                if w["signed_error"] is None
            ],
        )
        report.update(discrepancy_statistics(metric_windows))
        available = (
            "COMPARED"
            if len(valid) == len(metric_windows)
            else "PARTIAL"
            if valid
            else "UNAVAILABLE"
        )
        report["analysis_status"] = available
        report["status"] = available
        if check_acceptance:
            verdict = (
                "INCOMPLETE"
                if available != "COMPARED"
                else "UNSCORED"
                if acceptance is None
                else "FAIL"
                if bad_fraction > bad_limit + 1e-12
                else "PASS"
            )
            report.update(
                status=verdict,
                acceptance_check={
                    "status": verdict,
                    "policy": acceptance,
                    "bad_duration_fraction": bad_fraction,
                },
            )
        findings.extend(
            difference_windows(
                name, metric_windows, metric.get("components_to_inspect", [])
            )
        )
    # Rank within each metric; different metric units cannot share an error-area ranking.
    findings.sort(key=lambda f: (f["metric"], -f["absolute_error_area"]))
    attach_context(findings, by_metric, edges, reports)
    for index, finding in enumerate(findings):
        finding["id"] = f"finding-{index + 1:04d}"
    availability = [r["analysis_status"] for r in reports.values()]
    analysis_status = (
        "ANALYZED"
        if all(a == "COMPARED" for a in availability)
        else "PARTIAL"
        if any(a in {"COMPARED", "PARTIAL"} for a in availability)
        else "UNAVAILABLE"
    )
    verdict = None
    if check_acceptance:
        required = [r["status"] for r in reports.values() if r["required"]]
        verdict = (
            "INCOMPLETE"
            if issues
            or not required
            or any(s in {"INCOMPARABLE", "INCOMPLETE", "UNSCORED"} for s in required)
            else "FAIL"
            if "FAIL" in required
            else "PASS"
        )
    from . import evidence as evidence_module

    return {
        "schema_version": 2,
        "validator_version": __version__,
        "case_id": case["case_id"],
        "status": verdict if check_acceptance else analysis_status,
        "analysis_status": analysis_status,
        "mode": "acceptance-check" if check_acceptance else "evidence",
        "accuracy_verdict": None,
        "acceptance_check": {"requested": check_acceptance, "status": verdict},
        "data_kind": case.get("data_kind", "unspecified"),
        "split": case.get("split"),
        "split_group": case.get("split_group"),
        "policy_id": case.get("policy_id"),
        "policy_sha256": case.get("policy_sha256"),
        "bundle_evidence": case.get("bundle_evidence"),
        "contract_issues": issues,
        "input_comparability": "DECLARED_AND_CONSISTENT"
        if not issues
        else "NOT_ESTABLISHED",
        "manifest_sha256": digest(case_path),
        "validator_sha256": digest(Path(__file__)),
        "evidence_code_sha256": digest(Path(evidence_module.__file__)),
        "provenance": evidence,
        "comparison": period,
        "metrics": reports,
        "windows": windows,
        "source_inventory": {
            role: {
                "path": s["path"],
                "rows": len(s["rows"]),
                "columns": s["columns"],
                "first_mapped_time_s": s["times"][0] if s["times"] else None,
                "last_mapped_time_s": s["times"][-1] if s["times"] else None,
            }
            for role, s in sources.items()
        },
        "findings": findings,
        "difference_epsilon": 0.0,
        "agent_handoff": {
            "owner": "agent",
            "accuracy_assessment": None,
            "instructions": [
                "Establish input/metric comparability before reasoning about model behavior.",
                "Use magnitude, duration, phase and concurrent signals to assess the observed differences.",
                "Separate observations from causal hypotheses; cite intervals and source rows.",
                "Choose a discriminating diagnostic workload or added observation before modifying a mechanism.",
                "Record your assessment, remaining uncertainty, change and follow-up evidence; a tool exit is not task completion.",
            ],
        },
        "limitations": [
            "No per-request reference data is read or inferred.",
            "ANALYZED/PARTIAL/UNAVAILABLE describe evidence availability, never model correctness.",
            "Difference intervals include every numerically nonzero bin; practical importance and floating-point noise require agent judgment.",
            "Binned series use explicit piecewise-constant reconstruction; gauge snapshots are not direct time averages.",
            "Localized intervals reflect the selected bin width, not the exact event time or cause of a simulator bug.",
            "No clock fitting, DTW, amplitude normalization, gap filling or completion-tail truncation is applied.",
            "Integral and cumulative errors describe observed bins only; missing coverage cannot be treated as zero error.",
            "Metric statistics and error areas have metric-specific units; do not rank different units together.",
            "Input metadata and semantic declarations are supplied evidence, not independently authenticated.",
            "Causal attribution and adequacy judgments belong to the agent and its recorded evidence.",
        ],
    }


def write_report(report: dict, out: Path) -> None:
    if out.exists() and any(out.iterdir()):
        raise ContractError(f"output directory is not empty: {out}")
    out.mkdir(parents=True, exist_ok=True)
    summary = {k: v for k, v in report.items() if k not in {"windows", "findings"}}
    for name, value in [
        ("summary.json", summary),
        ("findings.json", report["findings"]),
    ]:
        (out / name).write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")
    fields = [
        "metric",
        "start_s",
        "end_s",
        "reference",
        "candidate",
        "reference_coverage",
        "candidate_coverage",
        "signed_error",
        "absolute_error",
        "relative_error",
        "difference_observed",
        "exceeds_tolerance",
        "signed_error_area_over_observed_bins",
        "absolute_error_area_over_observed_bins",
        "cumulative_observed_duration_s",
        "reference_rows",
        "candidate_rows",
    ]
    with (out / "window_errors.csv").open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        for row in report["windows"]:
            writer.writerow(
                {k: json.dumps(v) if isinstance(v, list) else v for k, v in row.items()}
            )
    lines = [
        f"{report['case_id']}: engine comparison evidence",
        f"Availability: {report['analysis_status']}",
        "Accuracy judgment: left to the agent",
        f"Data: {report['data_kind']}",
        "",
    ]
    lines.extend("INPUT: " + s for s in report["contract_issues"])
    for name, r in report["metrics"].items():
        lines.append(
            f"{name}: {r['analysis_status']} | MAE={r.get('mae')} {r['unit']} | signed bias={r.get('signed_bias')} | coverage={r.get('coverage_fraction')}"
        )
        lines.extend("  " + reason for reason in r.get("reasons", []))
        if r.get("peak_absolute_error"):
            peak = r["peak_absolute_error"]
            lines.append(
                f"  Peak difference [{peak['start_s']}, {peak['end_s']})s: reference={peak['reference']}, candidate={peak['candidate']}; first difference={r['first_difference_s']}"
            )
    lines.extend(
        [
            "",
            "Observed difference intervals (ranked within each metric, not an acceptance decision):",
        ]
    )
    for name in report["metrics"]:
        selected = [f for f in report["findings"] if f["metric"] == name]
        lines.extend(
            f"{f['id']}: {f['metric']} [{f['start_s']}, {f['end_s']})s {f['direction']}; mean difference={f['mean_signed_error']}; co-occurring={f['cooccurring_metrics']}"
            for f in selected[:3]
        )
        if len(selected) > 3:
            lines.append(
                f"  {len(selected) - 3} additional {name} intervals in findings.json."
            )
    lines.append(
        "Use python tools/validate.py inspect REPORT_DIR --metric NAME --start SECONDS --end SECONDS for bounded interval evidence; full findings and bins are retained."
    )
    if report["acceptance_check"]["requested"]:
        lines.extend(
            [
                "",
                f"Explicit optional acceptance check: {report['acceptance_check']['status']}",
            ]
        )
    lines.extend(
        ["", *report["agent_handoff"]["instructions"], "", *report["limitations"]]
    )
    text = "\n".join(lines) + "\n"
    (out / "summary.txt").write_text(text)
    from .presentation import html_report

    (out / "report.html").write_text(html_report(report, text))
