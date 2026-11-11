"""L4 RFI drafting — surface review-worthy findings from the CIR as RFI drafts.

An RFI (Request for Information) flags something the drawings leave uncertain. We generate
*drafts* (never auto-submit): low-confidence quantities the estimator should confirm, and
connectivity discrepancies (e.g. a panel with no detected circuits). Every draft carries its
evidence and a severity, so a human triages fast. This is decision support, not an oracle.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field

from cir import DrawingSet, EntityType

_PANEL_LABELS = {"panelboard", "consumer unit"}
_COUNTABLE_SKIP = frozenset(
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
class RFI:
    """A drafted request for information."""

    id: str
    discipline: str
    sheet: str
    severity: str  # "review" | "discrepancy"
    subject: str
    body: str
    evidence: list[str] = field(default_factory=list)  # entity ids

    def to_markdown(self) -> str:
        return (
            f"**RFI {self.id}** · {self.discipline} · {self.sheet} · _{self.severity}_\n\n"
            f"*{self.subject}*\n\n{self.body}"
        )


def generate_rfis(ds: DrawingSet, *, review_threshold: float = 0.5) -> list[RFI]:
    """Draft RFIs for ``ds``: low-confidence quantities + connectivity discrepancies."""
    rfis: list[RFI] = []
    n = 0

    for sheet in ds.sheets:
        disc = sheet.discipline.value if sheet.discipline else "unknown"
        # gather this sheet's countable entities + its connectivity
        low: dict[str, list[tuple[str, float]]] = defaultdict(list)  # label -> [(id, conf)]
        total: dict[str, int] = defaultdict(int)
        connected: set[str] = set()
        entities: dict[str, str] = {}  # id -> label (lower)
        for view in sheet.views:
            for c in view.connections:
                connected.add(c.source_id)
                connected.add(c.target_id)
            for e in view.entities:
                if e.entity_type in _COUNTABLE_SKIP or e.label is None:
                    continue
                total[e.label] += 1
                entities[e.id] = e.label.lower()
                if e.confidence < review_threshold:
                    low[e.label].append((e.id, e.confidence))

        # 1) low-confidence quantities → review RFIs
        for label, items in sorted(low.items()):
            n += 1
            rfis.append(
                RFI(
                    id=f"{n:03d}",
                    discipline=disc,
                    sheet=sheet.sheet_number,
                    severity="review",
                    subject=f"Confirm {label} quantity on {sheet.sheet_number}",
                    body=(
                        f"{len(items)} of {total[label]} '{label}' symbols were detected below "
                        f"{review_threshold:.0%} confidence. Please confirm the quantity and "
                        f"locations before takeoff is finalized."
                    ),
                    evidence=[i for i, _ in items],
                )
            )

        # 2) connectivity discrepancy → only if this sheet has any connectivity at all
        if connected:
            for eid, label in entities.items():
                if label in _PANEL_LABELS and eid not in connected:
                    n += 1
                    rfis.append(
                        RFI(
                            id=f"{n:03d}",
                            discipline=disc,
                            sheet=sheet.sheet_number,
                            severity="discrepancy",
                            subject=f"Panel with no detected circuits on {sheet.sheet_number}",
                            body=(
                                "A panelboard was detected with no connected home-runs/circuits "
                                "in the extracted connectivity graph. Verify the panel schedule "
                                "against the plan — circuits may be missing or unrouted."
                            ),
                            evidence=[eid],
                        )
                    )
    return rfis
