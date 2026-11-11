"""Deterministic scale recovery — no LLM.

Parses drawing-scale strings into a :class:`cir.Scale`. Downstream quantities depend
on scale, so this must be reliable and explainable, never guessed by a model. Handles
the common North-American imperial forms (``1/4" = 1'-0"``, ``3/16" = 1'-0"``,
``1" = 20'``) and metric ratios (``1:50``, ``1:100``). ``resolve_px`` converts a parsed
scale to pixels-per-real-unit at a given raster DPI.
"""

from __future__ import annotations

import re

from cir import Scale

# A number: integer, decimal, simple fraction, or mixed number ("1 1/2").
_NUM = r"(?:\d+\s+\d+/\d+|\d+/\d+|\d+(?:\.\d+)?)"

# Imperial: <paper>" = <feet>'(-<inches>")?  e.g. 1/4" = 1'-0",  1" = 20'
_IMPERIAL_RE = re.compile(
    rf'(?P<paper>{_NUM})\s*"\s*=\s*(?P<feet>\d+)\s*\'\s*' rf'(?:[-\s]*(?P<inch>{_NUM})\s*")?',
    re.IGNORECASE,
)
# Metric ratio: 1:50, 1 : 100
_METRIC_RE = re.compile(r"(?P<a>\d+(?:\.\d+)?)\s*:\s*(?P<b>\d+(?:\.\d+)?)")

_NTS_RE = re.compile(r"\b(NTS|NOT\s+TO\s+SCALE)\b", re.IGNORECASE)

# Inches per one real-world unit, for the px conversion.
_INCHES_PER_UNIT = {"ft": 12.0, "in": 1.0, "m": 39.37007874, "mm": 0.0393700787}


def _parse_number(text: str) -> float:
    """Parse an integer / decimal / fraction / mixed number to a float."""
    text = text.strip()
    if " " in text:  # mixed: "1 1/2"
        whole, frac = text.split(None, 1)
        return float(whole) + _parse_number(frac)
    if "/" in text:
        num, denom = text.split("/", 1)
        return float(num) / float(denom)
    return float(text)


def parse_scale(text: str) -> Scale | None:
    """Parse a scale string into a :class:`cir.Scale`, or ``None`` if not found.

    The returned scale's ``ratio`` is the dimensionless paper-length / real-length
    factor (e.g. ``1/4" = 1'-0"`` → ``0.25/12``; ``1:50`` → ``0.02``).
    """
    if not text or _NTS_RE.search(text):
        return None

    match = _IMPERIAL_RE.search(text)
    if match:
        paper_in = _parse_number(match.group("paper"))
        real_in = 12.0 * float(match.group("feet"))
        if match.group("inch"):
            real_in += _parse_number(match.group("inch"))
        if real_in > 0:
            return Scale(
                raw=match.group(0).strip(),
                drawing_unit="in",
                real_world_unit="ft",
                ratio=paper_in / real_in,
                confidence=0.99,
            )

    match = _METRIC_RE.search(text)
    if match:
        a, b = float(match.group("a")), float(match.group("b"))
        if b > 0:
            return Scale(
                raw=match.group(0).strip(),
                drawing_unit="mm",
                real_world_unit="m",
                ratio=a / b,
                confidence=0.95,
            )
    return None


def resolve_px(scale: Scale, dpi: float) -> Scale:
    """Return a copy of ``scale`` with ``px_per_real_unit`` computed for ``dpi``."""
    if scale.ratio is None or scale.real_world_unit is None:
        return scale
    inches = _INCHES_PER_UNIT.get(scale.real_world_unit)
    if inches is None:
        return scale
    return scale.model_copy(update={"px_per_real_unit": scale.ratio * inches * dpi})
