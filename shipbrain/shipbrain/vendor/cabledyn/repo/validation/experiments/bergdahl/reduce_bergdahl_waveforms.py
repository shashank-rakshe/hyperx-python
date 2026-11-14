#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Compare CableDyn with the 2 published Bergdahl force histories.

The experimental time origin is arbitrary.  A single circular phase shift is
therefore selected by least squares for each history.  Force offset and amplitude
are never adjusted.  Both signals are phase-averaged first so the comparison is
not affected by the number of complete cycles present in the digitised chart.
"""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np


CASES = (
    (1.25, 0.2, 1),
    (3.50, 0.2, 2),
)


def read_cabledyn_output(path: Path) -> tuple[np.ndarray, dict[str, np.ndarray]]:
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
        raise ValueError(f"{path}: data/header column mismatch")
    return values[:, 0], {name: values[:, index] for index, name in enumerate(names)}


def phase_average(
    time: np.ndarray,
    force: np.ndarray,
    period: float,
    cycle_starts: np.ndarray,
    nphase: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    phase = np.arange(nphase, dtype=float) / nphase
    sample_time = cycle_starts[:, None] + period * phase[None, :]
    cycles = np.vstack([np.interp(row, time, force) for row in sample_time])
    return phase, np.mean(cycles, axis=0), np.std(cycles, axis=0, ddof=1)


def best_phase_shift(measured: np.ndarray, predicted: np.ndarray) -> tuple[int, np.ndarray]:
    errors = np.asarray(
        [np.mean((measured - np.roll(predicted, shift)) ** 2) for shift in range(measured.size)]
    )
    shift = int(np.argmin(errors))
    return shift, np.roll(predicted, shift)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("case_directory", type=Path)
    parser.add_argument("experimental_data", type=Path)
    parser.add_argument("--phase-points", type=int, default=1000)
    args = parser.parse_args()
    if args.phase_points < 100:
        raise ValueError("phase-points must be at least 100")

    manifest = json.loads((args.case_directory / "case_manifest.json").read_text(encoding="utf-8"))
    experiment = np.loadtxt(args.experimental_data)
    experiment_time = experiment[:, 0]
    metrics = []

    for period, radius, experiment_column in CASES:
        matches = [
            case
            for case in manifest
            if np.isclose(float(case["period_s"]), period)
            and np.isclose(float(case["radius_m"]), radius)
        ]
        if len(matches) != 1:
            raise ValueError(f"expected 1 numerical case for T={period}, r={radius}; found {len(matches)}")
        case = matches[0]
        output_path = args.case_directory / f"{case['case']}.out"
        time, channels = read_cabledyn_output(output_path)
        predicted_force = channels["FairTen1"]

        experimental_cycles = int(np.floor((experiment_time[-1] - experiment_time[0]) / period + 1.0e-10))
        if experimental_cycles < 2:
            raise ValueError(f"insufficient complete experimental cycles for T={period}")
        experimental_starts = experiment_time[0] + period * np.arange(experimental_cycles)
        numerical_start = float(case["analysis_start_s"])
        numerical_starts = numerical_start + period * np.arange(5)

        phase, measured_mean, measured_std = phase_average(
            experiment_time,
            experiment[:, experiment_column],
            period,
            experimental_starts,
            args.phase_points,
        )
        _, predicted_mean, predicted_std = phase_average(
            time,
            predicted_force,
            period,
            numerical_starts,
            args.phase_points,
        )
        shift, predicted_aligned = best_phase_shift(measured_mean, predicted_mean)
        predicted_std_aligned = np.roll(predicted_std, shift)
        signed_shift = shift if shift <= args.phase_points // 2 else shift - args.phase_points
        difference = predicted_aligned - measured_mean
        measured_range = float(np.ptp(measured_mean))
        correlation = float(np.corrcoef(measured_mean, predicted_aligned)[0, 1])
        row = {
            "period_s": period,
            "radius_m": radius,
            "experimental_cycles": experimental_cycles,
            "numerical_cycles": 5,
            "phase_shift_s": signed_shift * period / args.phase_points,
            "measured_phase_mean_maximum_N": float(np.max(measured_mean)),
            "predicted_phase_mean_maximum_N": float(np.max(predicted_aligned)),
            "maximum_error_percent": float(
                100.0 * (np.max(predicted_aligned) - np.max(measured_mean)) / np.max(measured_mean)
            ),
            "mean_bias_N": float(np.mean(difference)),
            "rmse_N": float(np.sqrt(np.mean(difference**2))),
            "rmse_percent_of_measured_range": float(100.0 * np.sqrt(np.mean(difference**2)) / measured_range),
            "correlation": correlation,
        }
        metrics.append(row)

        output_rows = []
        for index in range(args.phase_points + 1):
            source = index % args.phase_points
            output_rows.append(
                {
                    "time_in_cycle_s": period * index / args.phase_points,
                    "measured_mean_N": float(measured_mean[source]),
                    "measured_std_N": float(measured_std[source]),
                    "predicted_mean_N": float(predicted_aligned[source]),
                    "predicted_std_N": float(predicted_std_aligned[source]),
                }
            )
        suffix = f"T{period:.2f}_R{radius:.3f}".replace(".", "p")
        with (args.case_directory / f"waveform_{suffix}.csv").open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(output_rows[0]))
            writer.writeheader()
            writer.writerows(output_rows)

    (args.case_directory / "waveform_metrics.json").write_text(json.dumps(metrics, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(metrics, indent=2))


if __name__ == "__main__":
    main()
