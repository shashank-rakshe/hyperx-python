"""Ground-truth self-validation — does a CIR document contain *exactly* what was asked for?

This lives in the eval harness (not in ``synthetic/``) on purpose: it is a reusable check
that any producer of CIR ground truth can run, and it is the gate the synthetic engine
uses before declaring a sample correct. The principle, from the spec: *if we asked for N
receptacles on M circuits, the CIR must contain exactly N receptacle entities, correctly
classed and placed, and exactly the M circuits as graph edges.* A mismatch is a generator
bug to fix — never a tolerance to accept — because subtly-wrong ground truth silently
poisons every model trained on it.

A :class:`GroundTruthExpectation` is the request expressed in CIR terms: per sheet, the
exact entity-label counts and connection-type counts, plus the exact placements of point
symbols. :func:`validate_ground_truth` checks a produced :class:`~cir.DrawingSet` against
it with **no tolerance on counts** (placement uses a tiny float epsilon). "Class" is read
through the same :func:`eval.metrics._label` the scoring metrics use, so the validator and
the leaderboard agree on what an entity *is*.
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field

from cir import DrawingSet, Sheet

from .metrics import _label


@dataclass(frozen=True)
class ExpectedPlacement:
    """A point symbol that must exist, with this label, centered here (within epsilon)."""

    sheet_number: str
    label: str
    x: float
    y: float


@dataclass(frozen=True)
class SheetExpectation:
    """The exact contents expected on one sheet."""

    sheet_number: str
    entity_label_counts: dict[str, int]  # label -> exact count (no extras allowed)
    edge_type_counts: dict[str, int] = field(default_factory=dict)  # connection_type -> exact count


@dataclass(frozen=True)
class GroundTruthExpectation:
    """The full request a produced :class:`~cir.DrawingSet` must satisfy exactly."""

    sample_id: str
    sheets: list[SheetExpectation]
    placements: list[ExpectedPlacement] = field(default_factory=list)


@dataclass(frozen=True)
class ValidationIssue:
    """One specific way the CIR diverged from the expectation."""

    code: str  # machine-readable: missing_sheet | entity_count | entity_total | edge_count | ...
    sheet: str
    detail: str


@dataclass
class ValidationReport:
    """The result of validating one sample. ``ok`` iff there are no issues."""

    sample_id: str
    issues: list[ValidationIssue] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.issues

    def _add(self, code: str, sheet: str, detail: str) -> None:
        self.issues.append(ValidationIssue(code=code, sheet=sheet, detail=detail))


def _sheet_label_counts(sheet: Sheet) -> Counter[str]:
    return Counter(_label(e) for e in sheet.iter_entities())


def _sheet_edge_counts(sheet: Sheet) -> Counter[str]:
    counts: Counter[str] = Counter()
    for view in sheet.views:
        for conn in view.connections:
            counts[conn.connection_type or "untyped"] += 1
    return counts


def _has_entity_at(sheet: Sheet, label: str, x: float, y: float, tol: float) -> bool:
    for entity in sheet.iter_entities():
        if _label(entity) != label or entity.geometry is None:
            continue
        bounds = entity.geometry.bounds()
        if bounds is None:
            continue
        center = bounds.center
        if abs(center.x - x) <= tol and abs(center.y - y) <= tol:
            return True
    return False


def validate_ground_truth(
    expectation: GroundTruthExpectation,
    drawing_set: DrawingSet,
    *,
    place_tol: float = 1e-6,
) -> ValidationReport:
    """Validate ``drawing_set`` against ``expectation``. Empty issue list ⇒ exact match.

    Checks, per expected sheet: every expected label count exactly; that there are **no
    extra** entities (the per-sheet total must match); every expected edge-type count
    exactly, with no extra edges; and that every expected point symbol exists at its
    location. Reports *all* divergences (does not stop at the first) so a generator bug is
    fully characterized in one pass.
    """
    report = ValidationReport(sample_id=expectation.sample_id)
    sheets = {s.sheet_number: s for s in drawing_set.sheets}

    for se in expectation.sheets:
        sheet = sheets.get(se.sheet_number)
        if sheet is None:
            report._add("missing_sheet", se.sheet_number, "expected sheet not present in document")
            continue

        actual = _sheet_label_counts(sheet)
        for label, n in se.entity_label_counts.items():
            got = actual.get(label, 0)
            if got != n:
                report._add(
                    "entity_count", se.sheet_number, f"label {label!r}: expected {n}, got {got}"
                )
        expected_total = sum(se.entity_label_counts.values())
        actual_total = sum(actual.values())
        if actual_total != expected_total:
            deltas = {
                k: actual.get(k, 0)
                for k in set(actual) | set(se.entity_label_counts)
                if actual.get(k, 0) != se.entity_label_counts.get(k, 0)
            }
            report._add(
                "entity_total",
                se.sheet_number,
                f"expected {expected_total} entities total, got {actual_total}; per-label deltas {deltas}",
            )

        actual_edges = _sheet_edge_counts(sheet)
        for edge_type, n in se.edge_type_counts.items():
            got = actual_edges.get(edge_type, 0)
            if got != n:
                report._add(
                    "edge_count", se.sheet_number, f"edge {edge_type!r}: expected {n}, got {got}"
                )
        expected_edge_total = sum(se.edge_type_counts.values())
        actual_edge_total = sum(actual_edges.values())
        if actual_edge_total != expected_edge_total:
            report._add(
                "edge_total",
                se.sheet_number,
                f"expected {expected_edge_total} edges total, got {actual_edge_total}",
            )

    for placement in expectation.placements:
        sheet = sheets.get(placement.sheet_number)
        if sheet is None:
            report._add(
                "missing_sheet", placement.sheet_number, "placement references absent sheet"
            )
            continue
        if not _has_entity_at(sheet, placement.label, placement.x, placement.y, place_tol):
            report._add(
                "placement",
                placement.sheet_number,
                f"no {placement.label!r} entity centered at ({placement.x:.4f}, {placement.y:.4f})",
            )

    return report
