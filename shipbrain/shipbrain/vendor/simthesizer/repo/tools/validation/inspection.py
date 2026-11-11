"""Bounded temporal evidence views; no acceptance or causal verdict."""

import csv
import json
import math


def row_excerpt(rows):
    return {
        "count": len(rows),
        "first": rows[:3],
        "last": rows[-3:],
        "complete": len(rows) <= 3,
    }


def inspect_report(args):
    if not 1 <= args.limit <= 20 or args.offset < 0:
        raise ValueError("limit must be 1..20 and offset nonnegative")
    if (args.start is None) != (args.end is None):
        raise ValueError("supply both --start and --end")
    if args.start is not None and not (
        math.isfinite(args.start) and math.isfinite(args.end) and args.start < args.end
    ):
        raise ValueError("require finite start < end")
    report = args.report
    summary = json.loads((report / "summary.json").read_text())
    findings = json.loads((report / "findings.json").read_text())
    names = [args.metric] if args.metric else list(summary["metrics"])
    if any(n not in summary["metrics"] for n in names):
        raise ValueError("unknown metric")
    view = {
        "case_id": summary["case_id"],
        "analysis_status": summary["analysis_status"],
        "contract_issues": summary["contract_issues"],
        "metrics": {},
        "sources": {
            n: str(report / n)
            for n in ["summary.json", "findings.json", "window_errors.csv"]
        },
        "interpretation": "Ranked within each metric by absolute error area; no importance or causal verdict. Bins overlapping a selected interval retain their original bounds.",
    }
    for name in names:
        metric = summary["metrics"][name]
        selected = [
            f
            for f in findings
            if f["metric"] == name
            and (
                args.start is None
                or f["end_s"] > args.start
                and f["start_s"] < args.end
            )
        ]
        selected.sort(key=lambda f: -f["absolute_error_area"])
        compact = []
        for finding in selected[args.offset : args.offset + args.limit]:
            item = {
                k: finding[k]
                for k in [
                    "id",
                    "start_s",
                    "end_s",
                    "direction",
                    "mean_signed_error",
                    "absolute_error_area",
                    "peak_absolute_error",
                ]
            }
            item["source_rows"] = {
                k: row_excerpt(v) for k, v in finding["evidence"].items()
            }
            item["concurrent_signals"] = {
                n: {k: v for k, v in data.items() if k != "source_rows"}
                for n, data in finding["concurrent_signals"].items()
            }
            compact.append(item)
        view["metrics"][name] = {
            "aggregate": {
                k: metric.get(k)
                for k in [
                    "unit",
                    "analysis_status",
                    "coverage_fraction",
                    "mae",
                    "signed_bias",
                    "wape",
                    "first_difference_s",
                    "last_difference_end_s",
                    "peak_absolute_error",
                ]
            },
            "findings": compact,
            "total_matching_findings": len(selected),
            "offset": args.offset,
            "more_findings": args.offset + args.limit < len(selected),
        }
    if args.start is not None:
        count = 0
        bins = []
        with (report / "window_errors.csv").open() as handle:
            for row in csv.DictReader(handle):
                if (
                    row["metric"] in names
                    and float(row["end_s"]) > args.start
                    and float(row["start_s"]) < args.end
                ):
                    if args.offset <= count < args.offset + args.limit:
                        bins.append(row)
                    count += 1
        view.update(
            bins=bins,
            total_matching_bins=count,
            more_bins=args.offset + args.limit < count,
        )
    return view
