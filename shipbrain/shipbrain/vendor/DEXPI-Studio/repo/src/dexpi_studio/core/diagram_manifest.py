"""Model-first diagram render manifest used by the GUI canvas.

This module intentionally lives in ``core/`` and contains no PySide imports.
"""

from __future__ import annotations

from dataclasses import dataclass, field

Point2D = tuple[float, float]
RgbaColor = tuple[int, int, int, int]


@dataclass(slots=True)
class DiagramTextLabel:
    """Text label in diagram coordinates."""

    text: str
    x: float
    y: float
    color: RgbaColor
    size: float
    anchor: str
    baseline: str
    rotation_deg: float


@dataclass(slots=True)
class DiagramRenderManifest:
    """Precomputed per-object render metadata for the canvas."""

    equipment_bounds: dict[str, tuple[float, float, float, float]] = field(default_factory=dict)
    equipment_paths: dict[str, list[list[Point2D]]] = field(default_factory=dict)
    equipment_colors: dict[str, RgbaColor] = field(default_factory=dict)
    equipment_dash_patterns: dict[str, list[float]] = field(default_factory=dict)
    equipment_stroke_widths: dict[str, float] = field(default_factory=dict)
    piping_paths: dict[str, list[list[Point2D]]] = field(default_factory=dict)
    pipe_colors: dict[str, RgbaColor] = field(default_factory=dict)
    pipe_dash_patterns: dict[str, list[float]] = field(default_factory=dict)
    pipe_stroke_widths: dict[str, float] = field(default_factory=dict)
    text_labels: list[DiagramTextLabel] = field(default_factory=list)
