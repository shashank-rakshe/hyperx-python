"""Sheet handling: title-block parsing, sheet numbering, and cross-reference callouts.

All deterministic / regex-based. Operates on the text recovered from a sheet (vector
PDF text or DXF/MTEXT). Sheet numbers follow the discipline-letter + number convention
(``A-101``, ``E-201``, ``S-100``); detail callouts follow ``detail/sheet`` (``3/A-501``,
``A/S-101``) and become :class:`cir.CrossReference` edges of the project sheet-graph.
"""

from __future__ import annotations

import re

from cir import CrossReference, Discipline, Scale, TitleBlock

from .scale import parse_scale

# Discipline letter (US National CAD Standard) -> Discipline.
_DISCIPLINE_BY_LETTER: dict[str, Discipline] = {d.code: d for d in Discipline}

# A sheet number: 1-2 discipline letters, optional dash, 2-4 digits, optional suffix.
_SHEET_NUMBER_RE = re.compile(r"\b([A-Z]{1,2})-?(\d{2,4})([A-Za-z])?\b")
# A detail callout: <detail> / <sheet number>, e.g. "3/A-501", "A/S-101".
_CALLOUT_RE = re.compile(r"\b([0-9A-Z]{1,3})\s*/\s*([A-Z]{1,2}-?\d{2,4}[A-Za-z]?)\b")
# A "SCALE: ..." label.
_SCALE_LABEL_RE = re.compile(r"SCALE\s*[:=]?\s*(.+)", re.IGNORECASE)


def discipline_for_letter(letter: str) -> Discipline | None:
    """Map a leading sheet-number letter (e.g. ``"E"``) to a :class:`cir.Discipline`."""
    return _DISCIPLINE_BY_LETTER.get(letter.upper())


def parse_sheet_number(text: str) -> str | None:
    """Find a plausible sheet number, preferring one near a ``SHEET`` label."""
    for line in text.splitlines():
        if "SHEET" in line.upper():
            match = _SHEET_NUMBER_RE.search(line)
            if match:
                return _format_sheet_number(match)
    match = _SHEET_NUMBER_RE.search(text)
    return _format_sheet_number(match) if match else None


def _format_sheet_number(match: re.Match[str]) -> str:
    letters, digits, suffix = match.group(1), match.group(2), match.group(3) or ""
    return f"{letters}-{digits}{suffix}"


def extract_scale(text: str) -> Scale | None:
    """Recover the drawing scale from a 'SCALE: ...' label or any scale token."""
    label = _SCALE_LABEL_RE.search(text)
    if label:
        scale = parse_scale(label.group(1))
        if scale is not None:
            return scale
    return parse_scale(text)


def find_cross_references(text: str) -> list[CrossReference]:
    """Find detail callouts (``detail/sheet``) and return them as CrossReference edges."""
    seen: set[tuple[str, str]] = set()
    refs: list[CrossReference] = []
    for match in _CALLOUT_RE.finditer(text):
        detail, sheet = match.group(1), match.group(2)
        key = (detail, sheet)
        if key in seen:
            continue
        seen.add(key)
        refs.append(
            CrossReference(
                callout=match.group(0).strip(),
                target_sheet=sheet,
                target_detail=detail,
                confidence=0.9,
            )
        )
    return refs


def parse_title_block(text: str) -> tuple[TitleBlock, Scale | None]:
    """Recover title-block fields + scale from a sheet's text (best-effort, deterministic)."""
    sheet_number = parse_sheet_number(text)
    scale = extract_scale(text)
    discipline = discipline_for_letter(sheet_number[0]) if sheet_number else None
    title_block = TitleBlock(
        sheet_number=sheet_number,
        discipline=discipline,
        scale=scale.raw if scale else None,
    )
    return title_block, scale
