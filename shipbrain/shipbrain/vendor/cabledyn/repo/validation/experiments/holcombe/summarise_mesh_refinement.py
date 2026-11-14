#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Summarise marker-position changes across the Holcombe spatial meshes."""

from __future__ import annotations

import argparse
import csv
import math
from pathlib import Path


ROOT = Path(__file__).resolve().parent


def comparison_path(directory: Path, representation: str, end: str, h: float) -> Path:
    token = f"{h:.3f}".replace(".", "p")
    return directory / f"holcombe_L3p67_{representation}_{end}_h{token}.marker_comparison.csv"


def marker_positions(path: Path) -> dict[int, tuple[float, float]]:
    with path.open(encoding="utf-8") as stream:
        return {
            int(row["marker"]):
            (float(row["x_cabledyn_m"]), float(row["z_cabledyn_m"]))
            for row in csv.DictReader(stream)
            if int(row["marker"]) != 7
        }


def element_count(directory: Path, representation: str, end: str, h: float) -> int:
    with (directory / "comparison_summary.csv").open(encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    for row in rows:
        if row["representation"] == representation and row["end_condition"] == end:
            return int(row["number_of_elements"])
    raise RuntimeError(f"missing summary row for {representation}, {end}, h={h}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Compare Holcombe marker positions at three mesh lengths."
    )
    parser.add_argument(
        "--coarse",
        type=Path,
        default=ROOT / "work" / "h0p020",
        help="directory reduced at a nominal 0.020 m element length",
    )
    parser.add_argument(
        "--primary",
        type=Path,
        default=ROOT / "work" / "h0p010",
        help="directory reduced at a nominal 0.010 m element length",
    )
    parser.add_argument(
        "--fine",
        type=Path,
        default=ROOT / "work" / "h0p005",
        help="directory reduced at a nominal 0.005 m element length",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=ROOT / "mesh_refinement_summary.csv",
        help="output CSV path",
    )
    args = parser.parse_args()
    meshes = {
        0.020: args.coarse.resolve(),
        0.010: args.primary.resolve(),
        0.005: args.fine.resolve(),
    }

    finest = 0.005
    rows: list[dict[str, object]] = []
    for representation in ("discrete", "distributed"):
        for end in ("rigid", "pinned"):
            reference = marker_positions(
                comparison_path(meshes[finest], representation, end, finest)
            )
            for h in (0.020, 0.010, 0.005):
                positions = marker_positions(
                    comparison_path(meshes[h], representation, end, h)
                )
                shifts = {
                    marker: 1000.0
                    * math.hypot(
                        positions[marker][0] - reference[marker][0],
                        positions[marker][1] - reference[marker][1],
                    )
                    for marker in reference
                }
                maximum_marker = max(shifts, key=shifts.get)
                rows.append(
                    {
                        "representation": representation,
                        "end_condition": end,
                        "nominal_element_length_m": h,
                        "number_of_elements": element_count(
                            meshes[h], representation, end, h
                        ),
                        "maximum_marker_shift_from_h0p005_mm": shifts[maximum_marker],
                        "maximum_shift_marker": maximum_marker,
                    }
                )

    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    for row in rows:
        print(
            f"{row['representation']} {row['end_condition']} "
            f"h={row['nominal_element_length_m']:.3f} m, "
            f"ne={row['number_of_elements']}: "
            f"max shift={row['maximum_marker_shift_from_h0p005_mm']:.6f} mm"
        )


if __name__ == "__main__":
    main()
