#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Reconstruct marker-scale curvature for the Holcombe static experiment.

The experiment reports marker positions rather than a continuous centreline or
direct curvature measurements.  This reducer therefore applies one identical
three-point (Menger) curvature operator to adjacent experimental and CableDyn
marker centres.  A deterministic coordinate grid spans the conservative
digitisation allowances retained by ``digitise_holcombe_fig7.py``.  The
resulting extrema are a digitisation-sensitivity envelope, not a statistical
confidence interval.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import itertools
import json
from pathlib import Path

import numpy as np


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_rows(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8") as stream:
        return list(csv.DictReader(stream))


def menger_curvature(points: np.ndarray) -> np.ndarray:
    """Return unsigned circumcircle curvature for arrays ending in (3, 2)."""

    p0 = points[..., 0, :]
    p1 = points[..., 1, :]
    p2 = points[..., 2, :]
    a = np.linalg.norm(p1 - p0, axis=-1)
    b = np.linalg.norm(p2 - p1, axis=-1)
    c = np.linalg.norm(p2 - p0, axis=-1)
    cross = (p1[..., 0] - p0[..., 0]) * (p2[..., 1] - p0[..., 1]) - (
        p1[..., 1] - p0[..., 1]
    ) * (p2[..., 0] - p0[..., 0])
    denominator = a * b * c
    if np.any(denominator <= np.finfo(float).tiny):
        raise ValueError("coincident marker coordinates make curvature undefined")
    return 2.0 * np.abs(cross) / denominator


def sensitivity_envelope(
    points: np.ndarray, uncertainty: np.ndarray, grid_levels: int
) -> tuple[float, float]:
    """Evaluate a tensor grid spanning each coordinate uncertainty interval."""

    levels = np.linspace(-1.0, 1.0, grid_levels)
    factors = np.asarray(list(itertools.product(levels, repeat=6)), dtype=float)
    perturbed = points[None, :, :] + factors.reshape(-1, 3, 2) * uncertainty[None, :, :]
    curvature = menger_curvature(perturbed)
    return float(np.min(curvature)), float(np.max(curvature))


def model_points(rows: list[dict[str, str]]) -> np.ndarray:
    return np.asarray(
        [[float(row["x_cabledyn_m"]), float(row["z_cabledyn_m"])] for row in rows],
        dtype=float,
    )


def write_space_table(path: Path, rows: list[dict[str, float]]) -> None:
    names = [
        "marker",
        "s",
        "exp",
        "exp_low",
        "exp_high",
        "exp_minus",
        "exp_plus",
        "pinned",
        "rigid",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write(" ".join(names) + "\n")
        for row in rows:
            stream.write(" ".join(f"{row[name]:.10g}" for name in names) + "\n")


def metrics(rows: list[dict[str, float]], model: str) -> dict[str, float]:
    # The last reconstructed station uses prescribed endpoint M7 as one of its
    # neighbours.  M2--M5 define the independent aggregate error measure.
    independent = rows[:-1]
    error = np.asarray([row[model] - row["exp"] for row in independent])
    return {
        "number_of_independent_curvature_stations": int(error.size),
        "bias_m_inv": float(np.mean(error)),
        "mae_m_inv": float(np.mean(np.abs(error))),
        "rmse_m_inv": float(np.sqrt(np.mean(error**2))),
        "maximum_absolute_error_m_inv": float(np.max(np.abs(error))),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("experimental_markers", type=Path)
    parser.add_argument("pinned_comparison", type=Path)
    parser.add_argument("rigid_comparison", type=Path)
    parser.add_argument("output_csv", type=Path)
    parser.add_argument("output_plot_table", type=Path)
    parser.add_argument("output_summary", type=Path)
    parser.add_argument("--grid-levels", type=int, default=9)
    args = parser.parse_args()
    if args.grid_levels < 3 or args.grid_levels % 2 == 0:
        raise ValueError("grid levels must be an odd integer of at least three")

    experimental_rows = read_rows(args.experimental_markers)
    pinned_rows = read_rows(args.pinned_comparison)
    rigid_rows = read_rows(args.rigid_comparison)
    if not (len(experimental_rows) == len(pinned_rows) == len(rigid_rows) == 7):
        raise ValueError("the Holcombe comparison requires seven ordered markers")

    experimental = np.asarray(
        [[float(row["x_m"]), float(row["z_m"])] for row in experimental_rows],
        dtype=float,
    )
    uncertainty = np.asarray(
        [
            [
                float(row["digitisation_uncertainty_x_m"]),
                float(row["digitisation_uncertainty_z_m"]),
            ]
            for row in experimental_rows
        ],
        dtype=float,
    )
    pinned = model_points(pinned_rows)
    rigid = model_points(rigid_rows)

    output_rows: list[dict[str, float]] = []
    for centre in range(1, 6):
        window = slice(centre - 1, centre + 2)
        exp_value = float(menger_curvature(experimental[window]))
        exp_low, exp_high = sensitivity_envelope(
            experimental[window], uncertainty[window], args.grid_levels
        )
        pinned_value = float(menger_curvature(pinned[window]))
        rigid_value = float(menger_curvature(rigid[window]))
        output_rows.append(
            {
                "marker": float(centre + 1),
                "s": float(experimental_rows[centre]["material_arc_m"]),
                "exp": exp_value,
                "exp_low": exp_low,
                "exp_high": exp_high,
                "exp_minus": exp_value - exp_low,
                "exp_plus": exp_high - exp_value,
                "pinned": pinned_value,
                "rigid": rigid_value,
                "pinned_error": pinned_value - exp_value,
                "rigid_error": rigid_value - exp_value,
            }
        )

    args.output_csv.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = list(output_rows[0].keys())
    with args.output_csv.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(output_rows)
    write_space_table(args.output_plot_table, output_rows)

    payload = {
        "definition": "unsigned three-point Menger curvature from adjacent marker centres",
        "interpretation": (
            "marker-scale geometric curvature; not a direct or continuous curvature measurement"
        ),
        "digitisation_sensitivity": {
            "coordinate_allowance": "plus or minus the tabulated two-source-pixel allowance",
            "grid_levels_per_coordinate": args.grid_levels,
            "evaluations_per_station": args.grid_levels**6,
            "interval_interpretation": "deterministic sensitivity envelope, not confidence interval",
        },
        "aggregate_station_definition": (
            "M2--M5; M6 is plotted but excluded because its stencil contains prescribed endpoint M7"
        ),
        "free_rotation": metrics(output_rows, "pinned"),
        "vertical_clamp": metrics(output_rows, "rigid"),
        "source_sha256": {
            "experimental_markers": sha256(args.experimental_markers),
            "free_rotation_comparison": sha256(args.pinned_comparison),
            "vertical_clamp_comparison": sha256(args.rigid_comparison),
        },
    }
    args.output_summary.write_text(
        json.dumps(payload, indent=2) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
