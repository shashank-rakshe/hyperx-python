#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Reduce CableDyn results for the Bergdahl et al. (2016) experiment."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np


def read_output(path: Path) -> tuple[np.ndarray, dict[str, np.ndarray]]:
    with path.open(encoding="utf-8") as stream:
        for line in stream:
            stripped = line.strip()
            if stripped and not stripped.startswith("#"):
                names = stripped.split()
                break
        else:
            raise ValueError(f"{path}: missing channel header")
        values = np.loadtxt(stream)
    if values.ndim == 1:
        values = values.reshape(1, -1)
    if values.shape[1] != len(names):
        raise ValueError(f"{path}: {values.shape[1]} columns do not match {len(names)} channel names")
    return values[:, 0], {name: values[:, index] for index, name in enumerate(names)}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("case_directory", type=Path)
    args = parser.parse_args()
    manifest = json.loads((args.case_directory / "case_manifest.json").read_text(encoding="utf-8"))
    rows = []
    traces = []
    for case in manifest:
        result_path = args.case_directory / f"{case['case']}.out"
        if not result_path.exists() or result_path.stat().st_size == 0:
            continue
        time, channels = read_output(result_path)
        analysis_start = float(case["analysis_start_s"])
        dt = float(case["dt_s"])
        period = float(case["period_s"])
        analysis_cycles = int(round((time[-1] - analysis_start) / period))
        if analysis_cycles != 5:
            raise ValueError(f"{case['case']}: expected five analysis cycles, found {analysis_cycles}")
        keep = time >= analysis_start - 0.5 * dt
        tension = channels["FairTen1"][keep]
        cycle_maxima = []
        for cycle in range(analysis_cycles):
            start = analysis_start + cycle * period
            stop = start + period
            in_cycle = (time >= start - 0.5 * dt) & (time < stop - 0.5 * dt)
            if not np.any(in_cycle):
                raise ValueError(f"{case['case']}: empty analysis cycle {cycle + 1}")
            cycle_maxima.append(float(np.max(channels["FairTen1"][in_cycle])))
        measured = float(case["measured_maximum_N"])
        predicted = float(np.mean(cycle_maxima))
        row = {
            **case,
            "samples_analysed": int(np.count_nonzero(keep)),
            "predicted_mean_N": float(np.mean(tension)),
            "predicted_minimum_N": float(np.min(tension)),
            "predicted_absolute_maximum_N": float(np.max(tension)),
            "predicted_mean_cycle_maximum_N": predicted,
            "predicted_cycle_maximum_std_N": float(np.std(cycle_maxima, ddof=1)),
            "predicted_range_N": float(np.ptp(tension)),
            "maximum_error_N": predicted - measured,
            "maximum_error_percent": 100.0 * (predicted - measured) / measured,
        }
        rows.append(row)
        if float(case["radius_m"]) == 0.2 and float(case["period_s"]) in (1.25, 3.5):
            local_time = time[keep] - time[keep][0]
            for t, force in zip(local_time, tension):
                traces.append({"case": case["case"], "time_s": float(t), "predicted_force_N": float(force)})
    if not rows:
        raise SystemExit("No completed output files found")
    with (args.case_directory / "comparison_summary.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    (args.case_directory / "comparison_summary.json").write_text(json.dumps(rows, indent=2) + "\n", encoding="utf-8")
    if traces:
        with (args.case_directory / "predicted_time_traces.csv").open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(traces[0]))
            writer.writeheader()
            writer.writerows(traces)
    if len(rows) != len(manifest):
        raise SystemExit(f"Only {len(rows)}/{len(manifest)} completed output files were available")
    measured = np.asarray([row["measured_maximum_N"] for row in rows])
    predicted = np.asarray([row["predicted_mean_cycle_maximum_N"] for row in rows])
    errors = predicted - measured
    correlation = float(np.corrcoef(measured, predicted)[0, 1])
    covariance = float(np.mean((measured - np.mean(measured)) * (predicted - np.mean(predicted))))
    concordance = float(
        2.0
        * covariance
        / (
            np.var(measured)
            + np.var(predicted)
            + (np.mean(measured) - np.mean(predicted)) ** 2
        )
    )
    aggregate = {
        "completed_cases": len(rows),
        "mean_bias_N": float(np.mean(errors)),
        "mean_bias_percent_of_measured": float(100.0 * np.mean(errors / measured)),
        "mae_N": float(np.mean(np.abs(errors))),
        "mape_percent": float(100.0 * np.mean(np.abs(errors) / measured)),
        "rmse_N": float(np.sqrt(np.mean(errors**2))),
        "maximum_absolute_error_percent": float(100.0 * np.max(np.abs(errors) / measured)),
        "pearson_correlation": correlation,
        "correlation_r_squared": correlation**2,
        "lin_concordance_correlation": concordance,
    }
    (args.case_directory / "aggregate_metrics.json").write_text(json.dumps(aggregate, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(aggregate, indent=2))


if __name__ == "__main__":
    main()
