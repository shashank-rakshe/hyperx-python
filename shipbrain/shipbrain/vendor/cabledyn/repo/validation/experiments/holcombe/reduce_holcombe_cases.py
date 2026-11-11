#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Reduce Holcombe static runs to measured-marker position errors."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np
from scipy.interpolate import PchipInterpolator


def read_static_profile(path: Path) -> dict[str, np.ndarray]:
    rows = []
    with path.open(encoding="utf-8") as stream:
        next(stream)
        names = next(stream).split()
        next(stream)
        for line in stream:
            if line.strip():
                rows.append([float(value) for value in line.split()])
    array = np.asarray(rows)
    return {name: array[:, index] for index, name in enumerate(names)}


def reference_nodes(section_csv: Path, element_profile: Path) -> np.ndarray:
    if element_profile.exists():
        rows = []
        with element_profile.open(encoding="utf-8") as stream:
            next(stream)
            names = next(stream).split()
            next(stream)
            for line in stream:
                if line.strip():
                    rows.append([float(value) for value in line.split()])
        array = np.asarray(rows)
        start = array[:, names.index("ReferenceArcStart")]
        end = array[:, names.index("ReferenceArcEnd")]
        return np.concatenate((start[:1], end))
    nodes = [0.0]
    cursor = 0.0
    with section_csv.open(encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            length = float(row["length_m"])
            count = int(row["segments"])
            for index in range(1, count + 1):
                nodes.append(cursor + index * length / count)
            cursor += length
    return np.asarray(nodes)


def measured_markers(path: Path, model_length: float) -> list[dict[str, float]]:
    result = []
    with path.open(encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            marker = int(row["marker"])
            arc = float(row["material_arc_m"])
            if marker == 7:
                arc = model_length
            result.append(
                {
                    "marker": marker,
                    "arc_m": arc,
                    "x_exp_m": float(row["x_m"]),
                    "z_exp_m": float(row["z_m"]),
                    "ux_m": float(row["digitisation_uncertainty_x_m"]),
                    "uz_m": float(row["digitisation_uncertainty_z_m"]),
                }
            )
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("case_directory", type=Path)
    parser.add_argument("marker_csv", type=Path)
    args = parser.parse_args()

    manifest_path = args.case_directory / "case_manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    summary = []
    for case in manifest:
        stem = case["case"]
        profile_path = args.case_directory / f"{stem}.static.out"
        if not profile_path.exists():
            continue
        profile = read_static_profile(profile_path)
        s_ref = reference_nodes(
            args.case_directory / f"{stem}.sections.csv",
            args.case_directory / f"{stem}.elements.out",
        )
        if len(s_ref) != len(profile["Node"]):
            raise RuntimeError(f"{stem}: {len(s_ref)} reference nodes != {len(profile['Node'])} output nodes")
        x_fun = PchipInterpolator(s_ref, profile["X"])
        z_fun = PchipInterpolator(s_ref, profile["Z"])
        marker_rows = []
        for marker in measured_markers(args.marker_csv, float(case["length_m"])):
            x_model = float(x_fun(marker["arc_m"]))
            z_model = float(z_fun(marker["arc_m"]))
            dx = x_model - marker["x_exp_m"]
            dz = z_model - marker["z_exp_m"]
            marker_rows.append(
                {
                    **marker,
                    "x_cabledyn_m": x_model,
                    "z_cabledyn_m": z_model,
                    "dx_m": dx,
                    "dz_m": dz,
                    "position_error_m": float(np.hypot(dx, dz)),
                }
            )
        output = args.case_directory / f"{stem}.marker_comparison.csv"
        with output.open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(marker_rows[0].keys()))
            writer.writeheader()
            writer.writerows(marker_rows)
        # Marker 7 is the tether attachment used to prescribe the second end
        # position.  Retain it in the profile table, but do not count a boundary
        # condition as an independently predicted marker in the error metrics.
        predicted_rows = [row for row in marker_rows if row["marker"] != 7]
        errors = np.array([row["position_error_m"] for row in predicted_rows])
        dx = np.array([row["dx_m"] for row in predicted_rows])
        dz = np.array([row["dz_m"] for row in predicted_rows])
        summary.append(
            {
                **case,
                "marker_position_rmse_m": float(np.sqrt(np.mean(errors**2))),
                "marker_position_mean_absolute_m": float(np.mean(errors)),
                "marker_position_max_m": float(np.max(errors)),
                "number_of_independent_markers": len(predicted_rows),
                "maximum_error_marker": int(predicted_rows[int(np.argmax(errors))]["marker"]),
                "x_bias_m": float(np.mean(dx)),
                "z_bias_m": float(np.mean(dz)),
                "maximum_nodal_curvature_per_m": float(np.max(profile["Curvature"])),
                "deformed_arc_length_m": float(profile["ArcLength"][-1]),
            }
        )
    (args.case_directory / "comparison_summary.json").write_text(
        json.dumps(summary, indent=2) + "\n", encoding="utf-8"
    )
    if summary:
        with (args.case_directory / "comparison_summary.csv").open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(summary[0].keys()))
            writer.writeheader()
            writer.writerows(summary)
    for row in summary:
        print(
            f"{row['case']}: RMSE={1000*row['marker_position_rmse_m']:.1f} mm, "
            f"max={1000*row['marker_position_max_m']:.1f} mm at M{row['maximum_error_marker']}"
        )


if __name__ == "__main__":
    main()
