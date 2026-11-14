# SPDX-License-Identifier: Apache-2.0
"""Synthetic CableDyn result files for the design post-processing tests."""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np

TIME = np.linspace(0.0, 10.0, 201)
NODES = (1, 3, 5)
ARC = {1: 0.0, 3: 50.0, 5: 100.0}


def _wave(mean: float, amplitude: float, frequency: float = 0.5, phase: float = 0.0):
    return mean + amplitude * np.sin(2.0 * math.pi * frequency * TIME + phase)


def node_channels() -> dict[str, np.ndarray]:
    """Node channels of line 1 at nodes 1, 3, 5 (tension, curvature, moment, position)."""
    columns: dict[str, np.ndarray] = {
        "FairTen1": _wave(1.0e6, 1.0e5),
        "Ten1N1": _wave(1.0e6, 1.0e5),
        "Ten1N03": _wave(8.0e5, 5.0e4),
        "ten1n5": np.full(TIME.shape, 6.0e5),
        "Curv1N1": _wave(0.01, 0.005),
        "Curv1N3": _wave(0.05, 0.02),
        "Curv1N5": np.full(TIME.shape, 0.02),
        "BendMom1N1": _wave(100.0, 50.0),
        "BendMom1N3": _wave(500.0, 200.0),
        "BendMom1N5": np.full(TIME.shape, 200.0),
        "Ten2N1": _wave(3.0e5, 1.0e4),
    }
    return columns


def write_main(path: Path, columns: dict[str, np.ndarray] | None = None) -> Path:
    """Write a native main output (no units row) with a time column."""
    data = node_channels() if columns is None else columns
    names = ("Time(s)", *data)
    rows = np.column_stack([TIME, *data.values()])
    lines = ["# CableDyn driver output (synthetic)", "\t".join(names)]
    lines.extend("\t".join(f"{value:.10E}" for value in row) for row in rows)
    path.write_text("\n".join(lines) + "\n", encoding="ascii")
    return path


def write_static(path: Path) -> Path:
    """Write a two-line static profile; line 1 has nodes 1..5 at 25 m spacing."""
    lines = [
        "CableDyn static configuration profile",
        "LineID\tNode\tArcLength\tX\tY\tZ\tTension\tCurvature\tBendMoment",
        "(-)\t(-)\t(m)\t(m)\t(m)\t(m)\t(N)\t(1/m)\t(N.m)",
    ]
    for node in range(1, 6):
        arc = 25.0 * (node - 1)
        curvature = [0.0, 0.01, 0.04, 0.02, 0.0][node - 1]
        z = -100.0 if node <= 2 else -100.0 + 30.0 * (node - 2)
        lines.append(
            f"1\t{node}\t{arc}\t{arc}\t0\t{z}\t{1.0e5 * node}\t{curvature}\t{1.0e4 * curvature}"
        )
    for node in range(1, 3):
        lines.append(f"2\t{node}\t{10.0 * (node - 1)}\t0\t0\t0\t1.0\t0.0\t0.0")
    path.write_text("\n".join(lines) + "\n", encoding="ascii")
    return path


def write_elements(path: Path) -> Path:
    """Write a Hermite element-extrema table for line 1 (two elements) and line 2."""
    lines = [
        "CableDyn continuous Hermite-element extrema (public order End A -> End B)",
        "LineID\tElement\tReferenceArcStart\tReferenceArcEnd\tPeakXi\tPeakReferenceArc\t"
        "PeakCurvature\tBendMomentAtPeak\tMinimumAxialResultant\tMinimumXi\t"
        "MaximumAxialResultant\tMaximumXi",
        "(-)\t(-)\t(m)\t(m)\t(-)\t(m)\t(1/m)\t(N.m)\t(N)\t(-)\t(N)\t(-)",
        "1\t2\t50\t100\t0.2\t60\t0.08\t800\t-10\t0.1\t2000\t0.9",
        "1\t1\t0\t50\t0.9\t45\t0.05\t500\t100\t0.0\t1000\t1.0",
        "2\t1\t0\t10\t0.5\t5\t0.01\t100\t1\t0.5\t2\t0.5",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="ascii")
    return path
