"""Shared sheet layout — the one place the renderer and the validator agree on identity.

The renderer (:mod:`synthetic.render`) and the validator's expectation
(:mod:`synthetic.expect`) must name the same sheets the same way, or a perfectly
correct render would look "wrong" to the validator. To keep them honest *and*
independent, the sheet-number scheme and the plan drawing region live here — imported
by both, defined once.

The plan drawing region also bounds where the scene generator may place devices, so the
floor-plan content never collides with the border or title block. Device coordinates are
normalized to the whole sheet (the CIR convention), so a position inside ``PLAN_REGION``
is already a CIR coordinate — there is no transform between the model and the ground truth.
"""

from __future__ import annotations

#: The interior rectangle (normalized) where plan content lives: (x0, y0, x1, y1).
#: The remaining right/bottom margin holds the border and title block.
PLAN_REGION: tuple[float, float, float, float] = (0.05, 0.07, 0.72, 0.82)

# Sheet roles -> the numeric part of the sheet number (after the discipline letter).
_SHEET_NUMBERS = {"plan": "101", "schedule": "601", "single_line": "301"}
_SHEET_TITLES = {
    "plan": "Power & Lighting Plan",
    "schedule": "Panel Schedule",
    "single_line": "Single-Line Diagram",
}


def sheet_number(prefix: str, role: str) -> str:
    """The sheet number for a role, e.g. ``("E", "plan") -> "E-101"``."""
    return f"{prefix}-{_SHEET_NUMBERS[role]}"


def sheet_title(role: str) -> str:
    """The human title for a sheet role."""
    return _SHEET_TITLES[role]


def plan_region_size() -> tuple[float, float]:
    """The (width, height) of the plan region in normalized units."""
    x0, y0, x1, y1 = PLAN_REGION
    return (x1 - x0, y1 - y0)
