#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Summarise selected Bergdahl spatial and temporal refinements.

The two published waveform conditions (radius 0.20 m and periods 1.25 and
3.50 s) are used for the refinement check.  The comparison quantity is the
mean of the maximum upper-end force over the final five cycles, identical to
the primary 30-condition assessment.
"""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np


TARGETS = ((1.25, 0.20), (3.50, 0.20))


def load(directory: Path) -> dict[tuple[float, float], float]:
    path = directory / "comparison_summary.csv"
    with path.open(encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    values = {
        (float(row["period_s"]), float(row["radius_m"])): float(
            row["predicted_mean_cycle_maximum_N"]
        )
        for row in rows
    }
    missing = [target for target in TARGETS if target not in values]
    if missing:
        raise ValueError(f"{path}: missing target conditions {missing}")
    return values


def main() -> None:
    parser = argparse.ArgumentParser()
    source_root = Path(__file__).resolve().parent
    work_root = source_root / "work"
    parser.add_argument(
        "--coarse-mesh", type=Path, default=work_root / "h0p400_dt0p0003125"
    )
    parser.add_argument("--primary", type=Path, default=work_root)
    parser.add_argument(
        "--fine-mesh", type=Path, default=work_root / "h0p100_dt0p0003125"
    )
    parser.add_argument(
        "--fine-step", type=Path, default=work_root / "h0p200_dt0p00015625"
    )
    parser.add_argument(
        "--coarse-step", type=Path, default=work_root / "h0p200_dt0p000625"
    )
    parser.add_argument(
        "--output-directory",
        type=Path,
        default=source_root,
        help="directory for refinement_summary.csv and refinement_summary.json",
    )
    args = parser.parse_args()
    definitions = {
        "h0p400_dt0p0003125": args.coarse_mesh.resolve(),
        "h0p200_dt0p0003125": args.primary.resolve(),
        "h0p100_dt0p0003125": args.fine_mesh.resolve(),
        "h0p200_dt0p00015625": args.fine_step.resolve(),
        "h0p200_dt0p000625": args.coarse_step.resolve(),
    }
    values = {name: load(directory) for name, directory in definitions.items()}
    spatial_reference = values["h0p100_dt0p0003125"]
    temporal_reference = values["h0p200_dt0p00015625"]

    rows: list[dict[str, float | str]] = []
    for period, radius in TARGETS:
        target = (period, radius)
        row: dict[str, float | str] = {
            "period_s": period,
            "radius_m": radius,
        }
        for name in definitions:
            row[f"force_{name}_N"] = values[name][target]
        for name in ("h0p400_dt0p0003125", "h0p200_dt0p0003125"):
            row[f"spatial_difference_{name}_percent"] = (
                100.0 * (values[name][target] - spatial_reference[target]) / spatial_reference[target]
            )
        for name in ("h0p200_dt0p0003125", "h0p200_dt0p000625"):
            row[f"temporal_difference_{name}_percent"] = (
                100.0 * (values[name][target] - temporal_reference[target]) / temporal_reference[target]
            )
        rows.append(row)

    output_directory = args.output_directory.resolve()
    output_directory.mkdir(parents=True, exist_ok=True)
    output_csv = output_directory / "refinement_summary.csv"
    with output_csv.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    primary_spatial = np.asarray(
        [float(row["spatial_difference_h0p200_dt0p0003125_percent"]) for row in rows]
    )
    primary_temporal = np.asarray(
        [float(row["temporal_difference_h0p200_dt0p0003125_percent"]) for row in rows]
    )
    payload = {
        "conditions": len(rows),
        "spatial_reference_nominal_element_length_m": 0.10,
        "temporal_reference_time_step_s": 0.00015625,
        "primary_nominal_element_length_m": 0.20,
        "primary_time_step_s": 0.0003125,
        "maximum_primary_spatial_difference_percent": float(np.max(np.abs(primary_spatial))),
        "maximum_primary_temporal_difference_percent": float(np.max(np.abs(primary_temporal))),
        "rows": rows,
    }
    (output_directory / "refinement_summary.json").write_text(
        json.dumps(payload, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(payload, indent=2))


if __name__ == "__main__":
    main()
