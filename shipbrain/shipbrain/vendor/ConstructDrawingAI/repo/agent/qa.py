"""L4 Q&A — deterministic structured questions over the CIR.

No external APIs and no LLM: for a liability-bearing product, drawing questions are answered
by *querying the grounded CIR*, and every answer carries its evidence (the exact entities +
sheets it counted). Handles the questions estimators/PMs actually ask — counts (optionally per
sheet), presence, listing, and drawing-set structure. An LLM front-end can later translate
free text into these same queries, but the answer itself stays grounded and auditable.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from cir import DrawingSet, EntityType

_NON_COUNTABLE = frozenset(
    {
        EntityType.TEXT,
        EntityType.DIMENSION,
        EntityType.LINE,
        EntityType.POLYLINE,
        EntityType.POLYGON,
        EntityType.SEGMENT,
        EntityType.GRAPH_NODE,
        EntityType.TABLE_CELL,
        EntityType.CALLOUT,
        EntityType.TITLE_BLOCK_FIELD,
        EntityType.LEGEND_ENTRY,
        EntityType.OTHER,
    }
)


@dataclass
class Answer:
    """A grounded answer: prose + the machine value + evidence links."""

    question: str
    text: str
    value: object = None  # int (count), list (items), or None (unresolved)
    evidence: list[tuple[str, str]] = field(default_factory=list)  # (sheet_number, entity_id)


@dataclass(frozen=True)
class _Row:
    sheet: str
    label: str
    entity_id: str
    confidence: float


def _rows(ds: DrawingSet, *, sheet: str | None = None) -> list[_Row]:
    out: list[_Row] = []
    for s in ds.sheets:
        if sheet is not None and s.sheet_number.lower() != sheet.lower():
            continue
        for v in s.views:
            for e in v.entities:
                if e.entity_type in _NON_COUNTABLE or e.label is None:
                    continue
                out.append(_Row(s.sheet_number, e.label, e.id, e.confidence))
    return out


def _singular(word: str) -> str:
    return word[:-1] if len(word) > 3 and word.endswith("s") else word


def _match(rows: list[_Row], subject: str) -> list[_Row]:
    """Rows whose label contains the subject (case-insensitive; plural-tolerant)."""
    subj = _singular(subject.strip().lower())
    if not subj:
        return rows
    return [r for r in rows if subj in r.label.lower()]


def answer(ds: DrawingSet, question: str) -> Answer:
    """Answer ``question`` against the CIR ``ds``. Deterministic; always returns an Answer."""
    q = question.strip().lower().rstrip("?")

    # optional "... on <sheet>" scope, e.g. "on E-201"
    sheet = None
    m = re.search(r"\bon\s+([a-z]{1,3}-?\d[\w.-]*)", q)
    if m:
        sheet = m.group(1)
        q = q[: m.start()].strip()

    if "disciplin" in q:
        discs = sorted({s.discipline.value for s in ds.sheets if s.discipline})
        return Answer(question, f"Disciplines present: {', '.join(discs) or 'none'}.", discs)

    if "sheet" in q and any(w in q for w in ("how many", "number of", "count", "list", "what")):
        nums = [s.sheet_number for s in ds.sheets]
        if any(w in q for w in ("list", "what")):
            return Answer(question, f"Sheets: {', '.join(nums)}.", nums)
        return Answer(question, f"{len(nums)} sheet(s): {', '.join(nums)}.", len(nums))

    rows = _rows(ds, sheet=sheet)
    scope = f" on {sheet.upper()}" if sheet else ""
    if sheet and not rows:
        return Answer(
            question, f"No sheet '{sheet.upper()}' found (or it has no components).", None
        )

    count_q = any(w in q for w in ("how many", "number of", "count", "how much"))
    list_q = any(w in q for w in ("list", "what are", "which", "show"))
    if count_q or list_q:
        subject = re.sub(
            r"^(how many|number of|count( of| the)?|how much|list( the)?|what are( the)?|which|show( me)?( the)?)",
            "",
            q,
        )
        subject = re.sub(
            r"\b(are|is|there|do|does|we|have|the|in|drawing|drawings|set)\b", " ", subject
        )
        matched = _match(rows, subject)
        ev = [(r.sheet, r.entity_id) for r in matched]
        name = subject.strip() or "components"
        if list_q and not count_q:
            by_label: dict[str, int] = {}
            for r in matched:
                by_label[r.label] = by_label.get(r.label, 0) + 1
            items = sorted(by_label.items(), key=lambda kv: -kv[1])
            body = ", ".join(f"{lab} ×{n}" for lab, n in items) or "none found"
            return Answer(question, f"{name.title()}{scope}: {body}.", items, ev)
        return Answer(question, f"{len(matched)} {name}{scope}.", len(matched), ev)

    return Answer(
        question,
        "I can answer counts ('how many receptacles on E-101'), listings ('list the panels'), "
        "and structure ('how many sheets', 'what disciplines').",
        None,
    )
