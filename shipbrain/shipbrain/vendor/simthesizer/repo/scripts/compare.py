"""Compare complete serving results by request, LLM call, and token identity."""

import argparse
import json
from pathlib import Path

from results import (
    LATENCIES,
    SCALARS,
    load_runs,
    measurements,
    metric_unit,
    paired_errors,
    percent,
    protect_output,
    relative_error,
    summarize,
    table,
)


def compare(runs, metrics, percentiles):
    reference = measurements(runs[0])
    rows = []
    for run in runs[1:]:
        candidate = measurements(run)
        for metric in metrics:
            a, b = reference[metric], candidate[metric]
            stats = percentiles if metric in LATENCIES else []
            left, right = summarize(a, stats), summarize(b, stats)
            rows.append(
                {
                    "candidate": run.label,
                    "metric": metric,
                    "unit": metric_unit(metric),
                    "reference": left,
                    "prediction": right,
                    "relative_error_pct": {
                        key: relative_error(value, right[key])
                        for key, value in left.items()
                    },
                    "paired": paired_errors(a, b) if metric in LATENCIES else None,
                }
            )
    return {
        "reference": runs[0].label,
        "files": {run.label: str(run.path) for run in runs},
        "metrics": rows,
    }


def render(report):
    sections = [
        f"Reference: {report['reference']}; relative error = 100 * (prediction - reference) / reference."
    ]
    for candidate in dict.fromkeys(row["candidate"] for row in report["metrics"]):
        rows = [row for row in report["metrics"] if row["candidate"] == candidate]
        summaries = [
            [
                row["metric"],
                row["unit"],
                stat,
                value,
                row["prediction"][stat],
                row["relative_error_pct"][stat],
            ]
            for row in rows
            for stat, value in row["reference"].items()
        ]
        pairs = [
            [
                row["metric"],
                row["unit"],
                *(
                    row["paired"][key]
                    for key in (
                        "count",
                        "mae",
                        "bias",
                        "mape_pct",
                        "mape_count",
                        "wape_pct",
                    )
                ),
            ]
            for row in rows
            if row["metric"] in LATENCIES
        ]
        sections.extend(
            [
                f"Candidate: {candidate}",
                table(
                    ["metric", "unit", "stat", "reference", "prediction", "error %"],
                    summaries,
                ),
            ]
        )
        if pairs:
            sections.append(
                table(
                    [
                        "metric",
                        "unit",
                        "n",
                        "MAE",
                        "bias",
                        "MAPE %",
                        "MAPE n",
                        "WAPE %",
                    ],
                    pairs,
                )
            )
    sections.append(
        "n/a: empty samples or zero denominator. MAPE excludes zero-reference samples; MAE includes them."
    )
    return "\n\n".join(sections)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", help="[LABEL=]PATH to reference result JSONL")
    parser.add_argument(
        "candidates", nargs="+", help="[LABEL=]PATH to candidate result JSONLs"
    )
    parser.add_argument(
        "--metrics",
        nargs="+",
        choices=[*LATENCIES, *SCALARS],
        default=[*LATENCIES, *SCALARS],
    )
    parser.add_argument("--percentiles", nargs="+", type=percent, default=[50, 95, 99])
    parser.add_argument(
        "--output", type=Path, help="also write a JSON report (times in seconds)"
    )
    args = parser.parse_args()
    try:
        runs = load_runs([args.reference, *args.candidates])
        report = compare(
            runs, list(dict.fromkeys(args.metrics)), sorted(set(args.percentiles))
        )
        if args.output:
            protect_output(args.output, runs)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
        print(render(report))
    except (ValueError, OSError) as exc:
        parser.exit(1, f"error: {exc}\n")


if __name__ == "__main__":
    main()
