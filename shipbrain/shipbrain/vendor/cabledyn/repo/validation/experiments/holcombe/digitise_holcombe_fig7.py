#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Digitise the experimental markers in Holcombe et al. (2025), Fig. 7.

The source graphic is the raster object embedded in the authors' open-access
PDF.  Axis calibration uses the seven labelled x ticks and six labelled z
ticks.  Coloured marker components are detected only inside the plotting
rectangle; their enclosing-box centres define the marker coordinates.  The
half diagonal of a source pixel after calibration is retained as the minimum
digitisation uncertainty.  This is deliberately a transparent plot
digitisation, not access to the experimental data archive.
"""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage


# Tick centres read at native image resolution.  A least-squares calibration
# avoids selecting a favourable pair of ticks.
X_TICK_PIXELS = np.array([145.5, 266.5, 387.5, 508.0, 629.0, 751.0, 872.5])
X_TICK_VALUES = np.arange(0.0, 3.5, 0.5)
Z_TICK_PIXELS = np.array([9.5, 130.0, 251.5, 373.0, 494.0, 615.0])
Z_TICK_VALUES = np.array([0.0, -0.2, -0.4, -0.6, -0.8, -1.0])


def linear_calibration(pixels: np.ndarray, values: np.ndarray) -> tuple[float, float]:
    slope, intercept = np.polyfit(pixels, values, 1)
    return float(slope), float(intercept)


def coloured_mask(rgb: np.ndarray) -> np.ndarray:
    maximum = rgb.max(axis=2)
    minimum = rgb.min(axis=2)
    yy, xx = np.indices(maximum.shape)
    # The line and axes are black.  A channel spread isolates the coloured
    # experimental-circle/OrcaFlex-triangle pairs without colour-specific bias.
    return (
        (maximum - minimum > 45)
        & (maximum > 100)
        & (xx >= 125)
        & (xx <= 979)
        & (yy >= 0)
        & (yy <= 630)
    )


def coloured_components(rgb: np.ndarray) -> list[dict[str, float]]:
    mask = coloured_mask(rgb)
    labels, count = ndimage.label(mask, structure=np.ones((3, 3), dtype=int))
    components: list[dict[str, float]] = []
    for label in range(1, count + 1):
        y, x = np.where(labels == label)
        if x.size < 12:
            continue
        # Marker pairs occupy compact 15--30 pixel envelopes.  Anti-aliasing
        # can split a pair, so retain only components in the expected regions.
        x0, x1 = int(x.min()), int(x.max())
        y0, y1 = int(y.min()), int(y.max())
        if x1 - x0 > 40 or y1 - y0 > 40:
            continue
        components.append(
            {
                "n_coloured_pixels": int(x.size),
                "pixel_x": 0.5 * (x0 + x1),
                "pixel_y": 0.5 * (y0 + y1),
                "pixel_x_min": x0,
                "pixel_x_max": x1,
                "pixel_y_min": y0,
                "pixel_y_max": y1,
            }
        )
    return components


def fit_experimental_circle(
    rgb: np.ndarray, component: dict[str, float]
) -> tuple[float, float, float, float]:
    """Separate the experimental circle from its overlaid triangle.

    The paper plots the physical measurement as a coloured circle and the
    OrcaFlex result as a triangle. Their envelopes overlap. A small circular
    Hough search gives the centre of the experimental symbol without using the
    numerical marker. The returned score is the mean circumference support.
    """

    mask = coloured_mask(rgb)
    margin = 3
    x0 = max(0, int(component["pixel_x_min"]) - margin)
    x1 = min(mask.shape[1] - 1, int(component["pixel_x_max"]) + margin)
    y0 = max(0, int(component["pixel_y_min"]) - margin)
    y1 = min(mask.shape[0] - 1, int(component["pixel_y_max"]) + margin)
    local = mask[y0 : y1 + 1, x0 : x1 + 1]
    labels, count = ndimage.label(local, structure=np.ones((3, 3), dtype=int))
    sizes = ndimage.sum(local, labels, range(1, count + 1))
    marker = labels == (1 + int(np.argmax(sizes)))
    holes = ndimage.binary_fill_holes(marker) & ~marker
    hole_labels, hole_count = ndimage.label(
        holes, structure=np.ones((3, 3), dtype=int)
    )
    hole_candidates = []
    for label in range(1, hole_count + 1):
        hole_y, hole_x = np.where(hole_labels == label)
        if hole_x.size < 4:
            continue
        centre_x = x0 + 0.5 * float(np.min(hole_x) + np.max(hole_x))
        centre_y = y0 + 0.5 * float(np.min(hole_y) + np.max(hole_y))
        hole_candidates.append((centre_x - centre_y, centre_x, centre_y))
    if not hole_candidates:
        raise RuntimeError("no enclosed symbol region found")
    # In every marker pair the experimental circle is the upper-right symbol;
    # the OrcaFlex triangle is lower-left. This follows directly from the
    # plotted symbols and avoids selecting the triangle with a circular fit.
    _, hole_cx, hole_cy = max(hole_candidates)
    distance = ndimage.distance_transform_edt(~local)
    angles = np.linspace(0.0, 2.0 * np.pi, 360, endpoint=False)
    cos_angle = np.cos(angles)
    sin_angle = np.sin(angles)
    best = (-np.inf, 0.0, 0.0, 0.0)
    for cx in np.arange(hole_cx - 3.0, hole_cx + 3.01, 0.25):
        for cy in np.arange(hole_cy - 3.0, hole_cy + 3.01, 0.25):
            for radius in np.arange(7.0, 11.01, 0.25):
                sample_x = cx - x0 + radius * cos_angle
                sample_y = cy - y0 + radius * sin_angle
                sampled = ndimage.map_coordinates(
                    distance,
                    [sample_y, sample_x],
                    order=1,
                    mode="constant",
                    cval=5.0,
                )
                support = float(np.mean(np.exp(-(sampled / 1.25) ** 2)))
                offset_squared = (cx - hole_cx) ** 2 + (cy - hole_cy) ** 2
                score = support - 0.5 * offset_squared
                if score > best[0]:
                    best = (score, cx, cy, radius)
    score, cx, cy, radius = best
    return cx, cy, radius, score


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    parser.add_argument("output_csv", type=Path)
    parser.add_argument("--metadata", type=Path)
    args = parser.parse_args()

    rgb = np.asarray(Image.open(args.image).convert("RGB"))
    sx, bx = linear_calibration(X_TICK_PIXELS, X_TICK_VALUES)
    sz, bz = linear_calibration(Z_TICK_PIXELS, Z_TICK_VALUES)
    components = coloured_components(rgb)

    expected_x = np.array([0.99, 1.41, 1.80, 2.16, 2.59, 2.93, 3.27])
    candidates = []
    for comp in components:
        x = sx * comp["pixel_x"] + bx
        z = sz * comp["pixel_y"] + bz
        if -0.05 <= x <= 3.40 and -1.02 <= z <= -0.15:
            comp = dict(comp)
            comp.update({"x_m": x, "z_m": z})
            candidates.append(comp)

    selected: list[dict[str, float]] = []
    used: set[int] = set()
    for target in expected_x:
        distances = [abs(c["x_m"] - target) if i not in used else np.inf for i, c in enumerate(candidates)]
        index = int(np.argmin(distances))
        if not np.isfinite(distances[index]) or distances[index] > 0.08:
            raise RuntimeError(f"no marker component found near x={target:.2f} m")
        used.add(index)
        comp = dict(candidates[index])
        circle_x, circle_y, circle_radius, circle_score = fit_experimental_circle(
            rgb, comp
        )
        comp.update(
            {
                "envelope_pixel_x": comp["pixel_x"],
                "envelope_pixel_y": comp["pixel_y"],
                "pixel_x": circle_x,
                "pixel_y": circle_y,
                "circle_radius_pixels": circle_radius,
                "circle_support_score": circle_score,
                "x_m": sx * circle_x + bx,
                "z_m": sz * circle_y + bz,
            }
        )
        selected.append(comp)

    # Retain two source pixels as a conservative allowance for the line width,
    # symbol overlap and axis calibration.
    ux = 2.0 * abs(sx)
    uz = 2.0 * abs(sz)
    args.output_csv.parent.mkdir(parents=True, exist_ok=True)
    with args.output_csv.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(
            stream,
            fieldnames=[
                "marker",
                "material_arc_m",
                "x_m",
                "z_m",
                "digitisation_uncertainty_x_m",
                "digitisation_uncertainty_z_m",
                "pixel_x",
                "pixel_y",
            ],
        )
        writer.writeheader()
        # Holcombe's 2026 thesis, Table 4.10, corrects the inconsistent
        # attachment stations printed in the 2025 article's Table 7.
        material_arc = [1.01, 1.44, 1.87, 2.30, 2.73, 3.16, 3.67]
        for marker, (arc, comp) in enumerate(zip(material_arc, selected), start=1):
            writer.writerow(
                {
                    "marker": marker,
                    "material_arc_m": f"{arc:.4f}",
                    "x_m": f"{comp['x_m']:.6f}",
                    "z_m": f"{comp['z_m']:.6f}",
                    "digitisation_uncertainty_x_m": f"{ux:.6f}",
                    "digitisation_uncertainty_z_m": f"{uz:.6f}",
                    "pixel_x": f"{comp['pixel_x']:.3f}",
                    "pixel_y": f"{comp['pixel_y']:.3f}",
                }
            )

    if args.metadata:
        args.metadata.write_text(
            json.dumps(
                {
                    "source_image": str(args.image),
                    "image_width_pixels": int(rgb.shape[1]),
                    "image_height_pixels": int(rgb.shape[0]),
                    "x_calibration_m_per_pixel": sx,
                    "x_calibration_intercept_m": bx,
                    "z_calibration_m_per_pixel": sz,
                    "z_calibration_intercept_m": bz,
                    "selected_components": selected,
                    "method": "least-squares tick calibration and circular Hough fit to experimental symbols",
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

    for marker, comp in enumerate(selected, start=1):
        print(f"M{marker}: x={comp['x_m']:.5f} m, z={comp['z_m']:.5f} m")


if __name__ == "__main__":
    main()
